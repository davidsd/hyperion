{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PolyKinds         #-}
{-# LANGUAGE TypeApplications  #-}
{-# LANGUAGE TypeFamilies      #-}
{-# LANGUAGE TypeOperators     #-}

module Hyperion.HoldServer where

import           Control.Concurrent.MVar     (MVar, modifyMVar_, newEmptyMVar,
                                              readMVar, tryPutMVar)
import           Control.Concurrent.STM      (atomically)
import           Control.Concurrent.STM.TVar (TVar, modifyTVar, newTVarIO,
                                              readTVarIO)
import           Control.Monad               (when)
import           Control.Monad.Catch         (catchIOError)
import           Control.Monad.IO.Class      (MonadIO, liftIO)
import           Data.Map                    (Map)
import qualified Data.Map                    as Map
import           Data.Maybe                  (catMaybes)
import           Data.Proxy                  (Proxy (..))
import qualified Data.Text                   as T
import qualified Hyperion.Log                as Log
import           Network.Wai                 ()
import           Network.Wai.Handler.Warp    (run)
import           Servant

type HoldApi =
       "release" :> Capture "service" T.Text :> Get '[JSON] (Maybe T.Text)
  :<|> "release-all" :> Get '[JSON] [T.Text]
  :<|> "list" :> Get '[JSON] [T.Text]

newtype HoldMap = HoldMap (TVar (Map T.Text (MVar ())))

newHoldMap :: IO HoldMap
newHoldMap = HoldMap <$> newTVarIO Map.empty

server :: HoldMap -> Server HoldApi
server (HoldMap holdMap) = releaseHold :<|> releaseAllHolds :<|> listHolds
  where
    releaseHold service = liftIO $ do
      serviceMap <- readTVarIO holdMap
      case Map.lookup service serviceMap of
        Just holdVar -> do
          unblocked <- tryPutMVar holdVar ()
          when (not unblocked) $ Log.warn "Service already unblocked" service
          atomically $ modifyTVar holdMap (Map.delete service)
          return (Just service)
        Nothing -> return Nothing
    listHolds = do
      liftIO $ fmap Map.keys (readTVarIO holdMap)
    releaseAllHolds = do
      services <- listHolds
      fmap catMaybes $ mapM releaseHold services

-- | Start a hold associated to the given service. Returns an IO action
-- that blocks until the hold is released
blockUntilReleased :: MonadIO m => HoldMap -> T.Text -> m ()
blockUntilReleased (HoldMap holdMap) service = liftIO $ do
  holdVar <- newEmptyMVar
  -- This will loose the blocking MVar if service is already blocked
  atomically $ modifyTVar holdMap (Map.insert service holdVar)
  readMVar holdVar

-- | Start the hold server. Initially try the port number in
-- portVar. In case of exception, increment portVar and try again.
runHoldServer :: HoldMap -> MVar Int -> IO ()
runHoldServer holdMap portVar = do
  port <- readMVar portVar
  run port (serve (Proxy @HoldApi) (server holdMap))
    `catchIOError` (\_ -> do
                       modifyMVar_ portVar (return . succ)
                       runHoldServer holdMap portVar)
