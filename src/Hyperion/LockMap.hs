{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE LambdaCase     #-}
{-# LANGUAGE StaticPointers #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}

module Hyperion.LockMap
  ( Key,
    LockMap,
    lockRemote,
    unlockRemote,
    isLockedRemote,
    newLockMap,
    registerLockMap
  )
where

import qualified Control.Concurrent.STM                   as STM
import           Control.Distributed.Process              (DiedReason (..), Process,                                                           ProcessId,
                                                           ProcessLinkException (..),
                                                           RemoteTable, call,
                                                           closure,                                                           getSelfPid, liftIO,
                                                           link, match,                                                           receiveWait, send,
                                                           spawnLocal, unStatic, ProcessMonitorNotification, monitor)
import           Control.Distributed.Process.Serializable (SerializableDict (..))
import           Control.Distributed.Static               (Static,
                                                           registerStatic,
                                                           staticLabel,
                                                           staticPtr)
import           Control.Monad                            (void)
import           Control.Monad.Catch                      (catch)
import           Control.Monad.Extra                      (unless)
import           Data.Binary                              (Binary, decode,
                                                           encode)
import           Data.ByteString.Lazy                     (ByteString)
import qualified Data.Map.Strict                          as Map
import           Data.Rank1Dynamic                        (toDynamic)
import           Data.Typeable                            (Typeable, typeOf)
import           Hyperion.Remote                          (getMasterNodeId)
import qualified Hyperion.Log as Log

-- Presence of () value indicates that the lock is locked
type Lock = STM.TMVar ()

data Key a = Key a

newLockedLock :: STM.STM Lock
newLockedLock = STM.newTMVar ()

isLocked :: Lock -> STM.STM Bool
isLocked l = not <$> STM.isEmptyTMVar l

-- Blocks
lock :: Lock -> STM.STM ()
lock = flip STM.putTMVar ()

-- Doesn't block
unlock :: Lock -> STM.STM ()
unlock = void . STM.tryTakeTMVar

wait :: Lock -> STM.STM ()
wait l = void $ STM.putTMVar l () >> STM.takeTMVar l

-- By default, all locks are open
type LockMap = STM.TVar (Map.Map ByteString Lock)

lockMapLabel :: String
lockMapLabel = "lockMapLabel"

lockMapStatic :: Static LockMap
lockMapStatic = staticLabel lockMapLabel

getLockMap :: Process LockMap
getLockMap = unStatic lockMapStatic

newLockMap :: IO LockMap
newLockMap = STM.newTVarIO Map.empty

registerLockMap :: LockMap -> RemoteTable -> RemoteTable
registerLockMap var = registerStatic lockMapLabel (toDynamic var)

lockRemote_ :: ByteString -> Process ()
lockRemote_ bs' = do
  getMasterNodeId >>= \case
    Nothing -> do
      let (pid, bs) = decode bs'
      lvar <- getLockMap
      l <- liftIO . STM.atomically $ do
        lmap <- STM.readTVar lvar
        let mlock = Map.lookup bs lmap
            lNew = do
              l <- newLockedLock
              STM.writeTVar lvar $ Map.insert bs l lmap
              return l
            lOld l = lock l >> return l
        maybe lNew lOld mlock
      pid' <- getSelfPid
      _ <- spawnLocal (watchDog pid pid' l)
      receiveWait [match $ \() -> return ()]
    Just nid ->
      call (staticPtr (static SerializableDict)) nid $
        closure (staticPtr (static lockRemote_)) bs'
  where
    watchDog :: ProcessId -> ProcessId -> Lock -> Process ()
    watchDog pid pid' l =
      catch
        ( do
            _ <- monitor pid
            send pid' ()
            msg <- receiveWait [match $ (\(p :: ProcessMonitorNotification) -> return $ show p)]
            Log.info "received message" msg
            liftIO . STM.atomically $ wait l
        )
        ( \(ProcessLinkException _ reason) ->
            unless (reason == DiedNormal) $ liftIO . STM.atomically $ unlock l
        )

unlockRemote_ :: ByteString -> Process ()
unlockRemote_ bs = do
  getMasterNodeId >>= \case
    Nothing -> do
      lvar <- getLockMap
      liftIO . STM.atomically $ do
        lmap <- STM.readTVar lvar
        let mlock = Map.lookup bs lmap
        maybe (return ()) unlock mlock
    Just nid ->
      call (staticPtr (static SerializableDict)) nid $
        closure (staticPtr (static unlockRemote_)) bs

isLockedRemote_ :: ByteString -> Process Bool
isLockedRemote_ bs = do
  getMasterNodeId >>= \case
    Nothing -> do
      lvar <- getLockMap
      liftIO . STM.atomically $ do
        lmap <- STM.readTVar lvar
        let mlock = Map.lookup bs lmap
        maybe (return False) isLocked mlock
    Just nid ->
      call (staticPtr (static SerializableDict)) nid $
        closure (staticPtr (static isLockedRemote_)) bs

serialize :: (Typeable a, Binary a) => a -> ByteString
serialize a = encode (typeOf a, a)

lockRemote :: (Typeable a, Binary a) => a -> Process (Key a)
lockRemote a = do
  pid <- getSelfPid
  lockRemote_ $ encode (pid, serialize a)
  return (Key a)

unlockRemote :: (Typeable a, Binary a) => Key a -> Process ()
unlockRemote (Key a) = unlockRemote_ $ serialize a

isLockedRemote :: (Typeable a, Binary a) => a -> Process Bool
isLockedRemote = isLockedRemote_ . serialize
