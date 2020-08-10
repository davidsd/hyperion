{-# LANGUAGE StaticPointers #-}

module Hyperion.LockMap where

import Control.Distributed.Process (Process, unStatic, RemoteTable, liftIO, NodeId, closure, Closure, call, getSelfNode)
import Control.Distributed.Static (Static, staticLabel, registerStatic, staticPtr)
import qualified Control.Concurrent.STM as STM
import Data.Rank1Dynamic (toDynamic)
import Data.ByteString.Lazy (ByteString)
import Data.ByteString.Lazy.Char8 (pack, unpack)
import Data.Binary (encode, Binary)
import Control.Distributed.Process.Serializable (SerializableDict (..), Serializable)
import Hyperion.Remote (getMasterNodeId, getDepth)
import Data.Typeable (Typeable, typeOf)
import Data.Maybe (fromMaybe)
import Control.Applicative (liftA2)
import qualified Data.Map.Strict as Map
import Control.Monad (void)

-- Presence of () value indicates that the lock is locked
type Lock = STM.TMVar ()

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
lockRemote_ bs = do
  depth <- getDepth
  if depth == 0 then do
    lvar <- getLockMap
    liftIO . STM.atomically $ do
      lmap <- STM.readTVar lvar
      let
        mlock = Map.lookup bs lmap
        goNew = do
          l <- newLockedLock
          STM.writeTVar lvar $ Map.insert bs l lmap
      maybe goNew lock mlock
  else
    callOnMaster (staticPtr (static SerializableDict)) $
      closure (staticPtr (static lockRemote_)) bs

unlockRemote_ :: ByteString -> Process ()
unlockRemote_ bs = do
  depth <- getDepth
  if depth == 0 then do
    lvar <- getLockMap
    liftIO . STM.atomically $ do
      lmap <- STM.readTVar lvar
      let
        mlock = Map.lookup bs lmap
      maybe (return ()) unlock mlock
  else
    callOnMaster (staticPtr (static SerializableDict)) $
      closure (staticPtr (static unlockRemote_)) bs

isLockedRemote_ :: ByteString -> Process Bool
isLockedRemote_ bs = do
  depth <- getDepth
  if depth == 0 then do
    lvar <- getLockMap
    liftIO . STM.atomically $ do
      lmap <- STM.readTVar lvar
      let
        mlock = Map.lookup bs lmap
      maybe (return False) isLocked mlock
  else
    callOnMaster (staticPtr (static SerializableDict)) $
      closure (staticPtr (static isLockedRemote_)) bs

callOnMaster :: (Binary a, Typeable a)
  => Static (SerializableDict a)
  -> Closure (Process a)
  -> Process a
callOnMaster d c = do
  nid <- (liftA2 fromMaybe) getSelfNode getMasterNodeId
  call d nid c

serialize :: (Typeable a, Binary a) => a -> ByteString
serialize a = encode (typeOf a, a)

lockRemote :: (Typeable a, Binary a) => a -> Process ()
lockRemote = lockRemote_ . serialize

unlockRemote :: (Typeable a, Binary a) => a -> Process ()
unlockRemote = unlockRemote_ . serialize

isLockedRemote :: (Typeable a, Binary a) => a -> Process Bool
isLockedRemote = isLockedRemote_ . serialize