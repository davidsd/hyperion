{-# LANGUAGE RankNTypes #-}

module Hyperion.CallClosure where

import           Control.Distributed.Process
import           Control.Distributed.Process.Closure                  (SerializableDict,
                                                                       bindCP,
                                                                       returnCP,
                                                                       sdictUnit,
                                                                       seqCP)
import           Control.Distributed.Process.Internal.Closure.BuiltIn (cpDelayed)
import           Control.Distributed.Static                           (closureApply,
                                                                       staticClosure,
                                                                       staticLabel)
import           Data.Binary                                          (Binary,
                                                                       encode)
import           Data.ByteString.Lazy                                 (ByteString)
import           Data.Typeable                                        (Typeable)

-- | The purpose of this module is to generalize 'call' from
-- 'Control.Distributed.Process' so that it takes a 'Closure
-- (SerializableDict a)' instead of a 'Static (SerializableDict
-- a)'. Note that this is a strict generalization because any 'Static
-- a' can be turned into 'Closure a' via 'staticClosure', while a
-- 'Closure a' cannot be turned into a 'Static a' in general.
--
-- Note: The extra flexibility afforded by call' is needed in
-- conjunction with the 'Hyperion.Static (KnownNat j)'
-- instance. In that case, we cannot construct a
-- 'Control.Distributed.Static.Static (Dict (KnownNat j))', but we can
-- construct a 'Closure (Dict (KnownNat j))'. NB: The name 'Static' is
-- used in two places: 'Control.Distributed.Static.Static' and
-- 'Hyperion.Static'. The former is a datatype and the latter
-- is a typeclass.
--
-- Most of the code here has been copied from
-- 'Control.Distributed.Process' and
-- 'Control.Distributed.Process.Closure', with small modifications.

-- | 'CP' version of 'send' that uses a 'Closure (SerializableDict a)'
-- instead of 'Static (SerializableDict a)'
cpSend' :: forall a . Closure (SerializableDict a) -> ProcessId -> Closure (a -> Process ())
cpSend' dict pid =
  staticClosure sendDictStatic `closureApply`
  dict `closureApply`
  closure decodeProcessIdStatic (encode pid)
  where
    sendDictStatic :: Static (SerializableDict a -> ProcessId -> a -> Process ())
    sendDictStatic = staticLabel "$sendDict"

    decodeProcessIdStatic :: Static (ByteString -> ProcessId)
    decodeProcessIdStatic = staticLabel "$decodeProcessId"

-- | 'call' that uses a 'Closure (SerializableDict a)' instead of a 'Static (SerializableDict a)'.
call'
  :: (Binary a, Typeable a)
  => Closure (SerializableDict a)
  -> NodeId
  -> Closure (Process a)
  -> Process a
call' dict nid proc = do
  us <- getSelfPid
  (pid, mRef) <- spawnMonitor nid (proc `bindCP`
                                   cpSend' dict us `seqCP`
                                   -- Delay so the process does not terminate
                                   -- before the response arrives.
                                   cpDelayed us (returnCP sdictUnit ())
                                  )
  mResult <- receiveWait
    [ match $ \a -> usend pid () >> return (Right a)
    , matchIf (\(ProcessMonitorNotification ref _ _) -> ref == mRef)
              (\(ProcessMonitorNotification _ _ reason) -> return (Left reason))
    ]
  case mResult of
    Right a  -> do
      -- Wait for the monitor message so that we the mailbox doesn't grow
      receiveWait
        [ matchIf (\(ProcessMonitorNotification ref _ _) -> ref == mRef)
                  (\(ProcessMonitorNotification {}) -> return ())
        ]
      -- Clean up connection to pid
      reconnect pid
      return a
    Left err ->
      fail $ "call: remote process died: " ++ show err

