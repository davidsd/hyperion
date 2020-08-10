{-# LANGUAGE StaticPointers #-}

module Hyperion.LockMap where

import Control.Distributed.Process (Process, unStatic, RemoteTable, liftIO, NodeId, closure, Closure, call)
import Control.Distributed.Static (Static, staticLabel, registerStatic, staticPtr)
import Control.Concurrent.STM (TVar, readTVarIO, atomically, writeTVar, newTVarIO)
import Data.Rank1Dynamic (toDynamic)
import Data.ByteString.Lazy (ByteString)
import Data.ByteString.Lazy.Char8 (pack, unpack)
import Data.Binary (encode, Binary)
import Control.Distributed.Process.Serializable (SerializableDict (..), Serializable)
import Hyperion.Remote (getHyperionNodeId)
import Data.Typeable (Typeable)

type LockMap = TVar String

lockMapLabel :: String
lockMapLabel = "lockMapLabel"

lockMapStatic :: Static LockMap
lockMapStatic = staticLabel lockMapLabel

getLockMap :: Process LockMap
getLockMap = unStatic lockMapStatic

newLockMap :: IO LockMap
newLockMap = newTVarIO "Hello lock maps"

registerLockMap :: TVar String -> RemoteTable -> RemoteTable
registerLockMap var = registerStatic lockMapLabel (toDynamic var)

readString_ :: ByteString -> Process String
readString_ _ = do
  tvar <- getLockMap
  liftIO $ readTVarIO tvar

putString_ :: ByteString -> Process ()
putString_ bs = do
  tvar <- getLockMap
  liftIO . atomically $ writeTVar tvar (unpack bs)

readStringClosure :: Closure (Process String)
readStringClosure = closure (staticPtr (static readString_)) (encode ())

putStringClosure :: String -> Closure (Process ())
putStringClosure = closure (staticPtr (static putString_)) . pack

callOnMaster :: (Binary a, Typeable a)
  => Static (SerializableDict a)
  -> Closure (Process a)
  -> Process a
callOnMaster d c = do
  nid <- getHyperionNodeId
  call d nid c

readString :: Process String
readString = callOnMaster (staticPtr (static SerializableDict)) readStringClosure

putString :: String -> Process ()
putString = callOnMaster (staticPtr (static SerializableDict)) . putStringClosure

--readString :: NodeId -> Process String


{-

lock :: ... -> RemoteLock   -- lock the lock (blocks)
unlock :: RemoteLock -> ... -- unlock the lock
lock' :: ... -> Maybe RemoteLock -- lock if unlocked (still blocks)
isLocked :: ... -> Bool

-}