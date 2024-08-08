{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE TypeFamilies        #-}
{-# LANGUAGE TypeOperators       #-}

-- | The Server allows a user to perform actions in a running Hyperion
-- program via a web api. For example, one can communicate with the
-- server on the command line via curl.

module Hyperion.Server
  ( ServerState
  , blockUntilRetried
  , storeCancelAction
  , onServiceExit
  , withHyperionServer
  , newServerState
  ) where

import Control.Concurrent.MVar     (MVar, newEmptyMVar, readMVar, tryPutMVar)
import Control.Concurrent.STM      (atomically)
import Control.Concurrent.STM.TVar (TVar, modifyTVar, newTVarIO, readTVarIO, stateTVar)
import Control.Monad               (when)
import Control.Monad.IO.Class      (MonadIO, liftIO)
import Data.Map                    (Map)
import Data.Map                    qualified as Map
import Data.Maybe                  (catMaybes)
import Hyperion.Log                qualified as Log
import Hyperion.ServiceId          (ServiceId (..))
import Network.Wai                 ()
import Network.Wai.Handler.Warp    qualified as Warp
import Servant

type HyperionApi =
       "retry"        :> Capture "serviceId" ServiceId :> Get '[JSON] (Maybe ServiceId)
  :<|> "retry-all"    :> Get '[JSON] [ServiceId]
  :<|> "list-retries" :> Get '[JSON] [ServiceId]
  :<|> "cancel"       :> Capture "serviceId" ServiceId :> Get '[JSON] (Maybe ServiceId)
  :<|> "list-cancels" :> Get '[JSON] [ServiceId]

-- | The 'holdMap' contains locks for ServiceId's that were cancelled or
-- died for some other reason. Calling "retry" or "retry-all" releases
-- the associated locks and allows the services to be re-computed.
--
-- The 'cancelMap' contains 'IO ()' actions that can cancel the given
-- ServiceId. In the Cluster monad, calling cancel on a ServiceId will
-- cause it to be eventually added to the holdMap, where one can also
-- "retry" it. In practice, "cancel" basically simulates some kind of
-- failure of the associated job by throwing an AsyncFailed exception
-- in the thread waiting for the job to finish.
data ServerState = MkServerState
  { holdMap   :: TVar (Map ServiceId (MVar ()))
  , cancelMap :: TVar (Map ServiceId (IO ()))
  }

newServerState :: IO ServerState
newServerState =
  MkServerState
  <$> newTVarIO Map.empty
  <*> newTVarIO Map.empty

server :: ServerState -> Server HyperionApi
server state =
  retryService state
  :<|> retryAll state
  :<|> listRetries state
  :<|> cancelService state
  :<|> listCancels state

listRetries :: MonadIO m => ServerState -> m [ServiceId]
listRetries state =
  liftIO $ fmap Map.keys (readTVarIO state.holdMap)

retryAll :: MonadIO m => ServerState -> m [ServiceId]
retryAll state = do
  services <- listRetries state
  fmap catMaybes $ mapM (retryService state) services

retryService :: MonadIO m => ServerState -> ServiceId -> m (Maybe ServiceId)
retryService state serviceId = liftIO $ do
  serviceMap <- readTVarIO state.holdMap
  case Map.lookup serviceId serviceMap of
    Just holdVar -> do
      unblocked <- tryPutMVar holdVar ()
      when (not unblocked) $ Log.warn "Service already unblocked" serviceId
      atomically $ modifyTVar state.holdMap (Map.delete serviceId)
      return (Just serviceId)
    Nothing -> return Nothing

-- | Start a hold associated to the given service. Returns an IO action
-- that blocks until the hold is released
blockUntilRetried :: MonadIO m => ServerState -> ServiceId -> m ()
blockUntilRetried state serviceId = liftIO $ do
  holdVar <- newEmptyMVar
  -- This will loose the blocking MVar if serviceId is already blocked
  atomically $ modifyTVar state.holdMap (Map.insert serviceId holdVar)
  readMVar holdVar

-- | Lookup the given serviceId in the cancelMap and run the
-- associated action if it exists. We also remove the action from the
-- cancelMap so that it cannot be run twice (which would result in an
-- error). A 'Just' return value indicates a successful
-- cancellation. 'Nothing' indicates that no cancel action was found.
cancelService :: MonadIO m => ServerState -> ServiceId -> m (Maybe ServiceId)
cancelService state serviceId = liftIO $ do
  maybeCancelAction <- atomically $
    stateTVar state.cancelMap $ \m ->
    (Map.lookup serviceId m, Map.delete serviceId m)
  case maybeCancelAction of
    Just action -> do
      action
      pure (Just serviceId)
    Nothing -> pure Nothing

-- | List all the ServiceId's that can be cancelled
listCancels :: MonadIO m => ServerState -> m [ServiceId]
listCancels state =
  liftIO $ fmap Map.keys (readTVarIO state.cancelMap)

-- | Store the given action in the cancelMap
storeCancelAction :: MonadIO m => ServerState -> ServiceId -> IO () -> m ()
storeCancelAction state serviceId cancelAction = liftIO $ 
  atomically $ modifyTVar state.cancelMap (Map.insert serviceId cancelAction)

-- | Remove the associated action from the cancelMap
onServiceExit :: MonadIO m => ServerState -> ServiceId -> m ()
onServiceExit state serviceId = liftIO $
  atomically $ modifyTVar state.cancelMap (Map.delete serviceId)

-- | Start the hold server on an available port and pass the port
-- number to the given action. The server is killed after the action
-- finishes.
--
withHyperionServer :: ServerState -> (Int -> IO a) -> IO a
withHyperionServer state = Warp.withApplication (pure app)
  where
    app = serve (Proxy @HyperionApi) (server state)
