{-# LANGUAGE DeriveAnyClass      #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StaticPointers      #-}

module Hyperion.LockMap
  ( LockMap,
    withLock,
    withLocks,
    newLockMap,
    registerLockMap
  )
where

import Control.Concurrent.STM                   qualified as STM
import Control.Distributed.Process              (DiedReason (..), Process,
                                                 ProcessId,
                                                 ProcessLinkException (..),
                                                 RemoteTable, call, closure,
                                                 getSelfPid, liftIO, link,
                                                 spawnLocal, unStatic)
import Control.Distributed.Process.Serializable (SerializableDict (..))
import Control.Distributed.Static               (Static, registerStatic,
                                                 staticLabel, staticPtr)
import Control.Monad                            (void)
import Control.Monad.Catch                      (bracket, catch)
import Control.Monad.Extra                      (unless)
import Data.Binary                              (Binary, decode, encode)
import Data.ByteString.Lazy                     (ByteString)
import Data.Map.Strict                          qualified as Map
import Data.Rank1Dynamic                        (toDynamic)
import Data.Typeable                            (Typeable, typeOf)
import Hyperion.Log                             qualified as Log
import Hyperion.Worker                          (getMasterNodeId)

-- Presence of a pid value indicates that the lock is locked by the process with the given ProcessId
type Lock = STM.TMVar ProcessId

newtype Key a = Key { unKey :: a }

--newLockedLock :: ProcessId -> STM.STM Lock
--newLockedLock = STM.newTMVar
--
--newUnlockedLock :: STM.STM Lock
--newUnlockedLock = STM.newEmptyTMVar

isLocked :: Lock -> STM.STM Bool
isLocked l = not <$> STM.isEmptyTMVar l

isUnlocked ::  Lock -> STM.STM Bool
isUnlocked l = not <$> isLocked l

-- Blocks
lock :: ProcessId -> Lock -> STM.STM ()
lock = flip STM.putTMVar

-- Doesn't block
unlock :: Lock -> STM.STM ()
unlock = void . STM.tryTakeTMVar

--wait :: Lock -> STM.STM ()
--wait l = STM.isEmptyTMVar l >>= \case
--  True -> return ()
--  False -> STM.retry

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
      let
        (pid, bss) = decode bs'
      -- Make sure there is a cleanup process linked to the original caller
      -- Create a signal TMVar for receiving a green light from the cleanup process
      sig  <- liftIO . STM.atomically $ STM.newEmptyTMVar
      -- TMVar that lets the cleanup process know what to clean up
      lvar <- liftIO . STM.atomically $ STM.newEmptyTMVar
      -- Start the cleanup process
      _    <- spawnLocal $ cleanup pid lvar sig
      -- Receive the signal from cleanup process that it is linked to the caller
      -- We can now safely acquire the locks
      ()   <- liftIO . STM.atomically $ STM.takeTMVar sig

      lmapvar <- getLockMap
      -- We perform a transaction where we lookup the locks by keys, create new locks if needed.
      -- We then peform a second transaction where
      --  If all locks are open, we lock them all with caller pid and send them to cleanup proc
      --  if at least one is closed, the transaction is retried (no changes to memory are recorded).
      -- We can use a single transaction, but it would be restarted each time someone accesses the lock map
      -- or our locks, rather than just our locks, which is a bit silly.
      locks <- liftIO . STM.atomically $ getLocks lmapvar bss
      liftIO . STM.atomically $ do
        unlocked <- mapM isUnlocked locks
        if all id unlocked then do
          mapM_ (lock pid) locks
          STM.putTMVar lvar locks
        else STM.retry
      return ()
    Just nid ->
      call (staticPtr (static SerializableDict)) nid $
        closure (staticPtr (static lockRemote_)) bs'
  where
    getLocks :: LockMap -> [ByteString] -> STM.STM [Lock]
    getLocks lmapvar bss = do
      mapM lookupOrNew bss
      where
        lookupOrNew :: ByteString -> STM.STM Lock
        lookupOrNew bs = do
          lmap <- STM.readTVar lmapvar
          let
            mlock = Map.lookup bs lmap
            new = do
                l <- STM.newEmptyTMVar
                STM.writeTVar lmapvar $ Map.insert bs l lmap
                return l
          maybe new return mlock

    cleanup :: ProcessId -> STM.TMVar [Lock] -> STM.TMVar () -> Process ()
    cleanup pid lvar sig =
      catch -- We catch the exceptions raised due to link to pid
        ( do
            link pid -- Link to pid
            liftIO . STM.atomically $ STM.putTMVar sig () -- Inform master process that we have linked
            liftIO . STM.atomically $ STM.readTMVar lvar >>= mapM_ wait -- Wait for the locks locked by our caller's pid
        )
        ( \(ProcessLinkException _ reason) ->
            -- We do not clean up if the caller died normally. It is the caller's responsibility to clean things up.
            -- This of course includes handled exceptions in the caller. In this case we clean up using 'bracket' in the
            -- caller.
            unless (reason == DiedNormal) $ do
              pidReleasedLock <- liftIO . STM.atomically $ do
                mlocks <- STM.tryReadTMVar lvar
                case mlocks of
                  Just locks -> do
                    releases <- flip mapM locks $ \l -> do
                      STM.tryReadTMVar l >>= \case
                        Just pid' -> if pid == pid' then do
                          unlock l
                          return False
                          else return True
                        Nothing   -> return True
                    return (all id releases)
                  Nothing -> return True
              unless pidReleasedLock $ Log.warn "Process holding a lock died, released the locks it held" pid
        )
      where
        wait :: Lock -> STM.STM ()
        wait l = STM.tryReadTMVar l >>= \case
          Just pid' -> if pid == pid' then STM.retry
                                      else return ()
          Nothing   -> return ()

unlockRemote_ :: ByteString -> Process ()
unlockRemote_ bss' =
  getMasterNodeId >>= \case
    Nothing -> do
      lvar <- getLockMap
      liftIO . STM.atomically $ do
        lmap <- STM.readTVar lvar
        let
          unlock' bs = maybe (return ()) unlock (Map.lookup bs lmap)
        mapM_ unlock' bss
    Just nid ->
      call (staticPtr (static SerializableDict)) nid $
        closure (staticPtr (static unlockRemote_)) bss'
  where
    bss :: [ByteString]
    bss = decode bss'

--isLockedRemote_ :: ByteString -> Process Bool
--isLockedRemote_ bs = do
--  getMasterNodeId >>= \case
--    Nothing -> do
--      lvar <- getLockMap
--      liftIO . STM.atomically $ do
--        lmap <- STM.readTVar lvar
--        let mlock = Map.lookup bs lmap
--        maybe (return False) isLocked mlock
--    Just nid ->
--      call (staticPtr (static SerializableDict)) nid $
--        closure (staticPtr (static isLockedRemote_)) bs

serialize :: (Typeable a, Binary a) => a -> ByteString
serialize a = encode (typeOf a, a)

lockRemote :: (Typeable a, Binary a) => [a] -> Process [Key a]
lockRemote a = do
  pid <- getSelfPid
  lockRemote_ $ encode (pid, map serialize a)
  return (map Key a)

unlockRemote :: (Typeable a, Binary a) => [Key a] -> Process ()
unlockRemote a = unlockRemote_ $ encode (map (serialize . unKey) a)

--isLockedRemote :: (Typeable a, Binary a) => a -> Process Bool
--isLockedRemote = isLockedRemote_ . serialize

withLocks :: (Typeable a, Binary a) => [a] -> Process r -> Process r
withLocks obj = bracket (lockRemote obj) unlockRemote . const

withLock :: (Typeable a, Binary a) => a -> Process r -> Process r
withLock a = withLocks [a]
