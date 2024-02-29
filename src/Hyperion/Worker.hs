{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase         #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE RecordWildCards    #-}
{-# LANGUAGE StaticPointers     #-}

module Hyperion.Worker
  ( ServiceId(..)
  , serviceIdToString
  , serviceIdToText
  , withServiceId
  , WorkerLauncher(..)
  , RemoteError(..)
  , RemoteProcessRunner
  , withRemoteRunProcess
  , mkSerializableClosureProcess
  , worker
  , getMasterNodeId
  , registerMasterNodeId
  , getWorkerStaticConfig
  , initWorkerRemoteTable
  ) where

import Control.Concurrent.MVar             (MVar, isEmptyMVar, newEmptyMVar,
                                            putMVar, readMVar)
import Control.Distributed.Process         hiding (bracket, catch, try)
import Control.Distributed.Process.Async   (AsyncResult (..), async, task, wait)
import Control.Distributed.Process.Closure (SerializableDict (..))
import Control.Distributed.Process.Node    qualified as Node
import Control.Distributed.Static          (registerStatic, staticLabel)
import Control.Monad.Catch                 (Exception, bracket, catch, throwM)
import Control.Monad.Extra                 (whenM)
import Control.Monad.Trans.Maybe           (MaybeT (..))
import Data.Binary                         (Binary)
import Data.Constraint                     (Dict (..))
import Data.Data                           (Typeable)
import Data.Foldable                       (asum)
import Data.Rank1Dynamic                   (toDynamic)
import Data.Text                           (Text, pack)
import Data.Time.Clock                     (NominalDiffTime)
import GHC.Generics                        (Generic)
import Hyperion.CallClosure                (call')
import Hyperion.Config                     (HyperionStaticConfig)
import Hyperion.Log                        qualified as Log
import Hyperion.Static                     (Serializable, ptrAp)
import Hyperion.Util                       (newUnique,
                                            nominalDiffTimeToMicroseconds,
                                            tryLogException)

-- | A label for a worker, unique for the given process (but not
-- unique across the whole distributed program).
newtype ServiceId = ServiceId String
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Binary)

serviceIdToText :: ServiceId -> Text
serviceIdToText = pack . serviceIdToString

serviceIdToString :: ServiceId -> String
serviceIdToString (ServiceId s) = s

data RemoteError = RemoteError ServiceId RemoteErrorType
  deriving (Show, Exception)

-- | Detailed type for 'RemoteError'. The constructors correspond to various
-- possible 'AsyncResult's.
data RemoteErrorType
  = RemoteAsyncFailed DiedReason
  | RemoteAsyncLinkFailed DiedReason
  | RemoteAsyncCancelled
  | RemoteAsyncPending
  | RemoteException String
  deriving (Show)

data WorkerConnectionTimeout = WorkerConnectionTimeout ServiceId
  deriving (Show, Exception)

-- | 'WorkerLauncher' type parametrized by a type for job id.
data WorkerLauncher j = WorkerLauncher
  { -- | A function that launches a worker for the given 'ServiceId' on
    -- the master 'NodeId' and supplies its job id to the given
    -- continuation
    withLaunchedWorker :: forall b . NodeId -> ServiceId -> (j -> Process b) -> Process b
    -- | Timeout for the worker to connect. If the worker is launched
    -- into a Slurm queue, it may take a very long time to connect. In
    -- that case, it is recommended to set 'connectionTimeout' =
    -- 'Nothing'.
  , connectionTimeout :: Maybe NominalDiffTime
    -- | A handler for 'RemoteError's.  'onRemoteError' can do things
    -- like blocking before rerunning the remote process, or simply
    -- rethrowing the error.
  , onRemoteError     :: forall b . RemoteError -> Process b -> Process b
  }

-- | Type for basic master to worker messaging
data WorkerMessage = Connected | ShutDown
  deriving (Read, Show, Generic, Binary)

-- | The main worker process.
--
-- Repeatedly (at most 5 times) send our own 'ProcessId' and the send
-- end of a typed channel ('SendPort' 'WorkerMessage') to a master
-- node until it replies 'Connected' (timeout 10 seconds for each
-- attempt).  Then 'expect' a 'ShutDown' signal.
--
-- While waiting, other processes will be run in a different thread,
-- invoked by master through our 'NodeId' (which it extracts from 'ProcessId')
worker
  :: NodeId     -- ^ 'NodeId' of the master node
  -> ServiceId  -- ^ 'ServiceId' of master 'Process' (should be 'register'ed)
  -> Process ()
worker masterNode serviceId@(ServiceId masterService) = do
  self <- getSelfPid
  (sendPort, receivePort) <- newChan

  let connectToMaster = MaybeT $ do
        Log.info "Connecting to master" masterNode
        nsendRemote masterNode masterService (self, serviceId, sendPort)
        receiveChanTimeout (10*1000*1000) receivePort

  runMaybeT (asum (replicate 5 connectToMaster)) >>= \case
    Just Connected -> do
      Log.text "Successfully connected to master."
      expect >>= \case
        Connected -> Log.throwError "Unexpected 'Connected' received."
        ShutDown  -> Log.text "Shutting down."
    _ -> Log.text "Couldn't connect to master" >> die ()

-- | Registers ('register') the current process under a random
-- 'ServiceId', then passes the 'ServiceId' to the given continuation.
-- After the continuation returns, unregisters ('unregister') the
-- 'ServiceId'.
withServiceId :: (ServiceId -> Process a) -> Process a
withServiceId = bracket newServiceId (\(ServiceId s) -> unregister s)
  where
    newServiceId = do
      s <- liftIO $ show <$> newUnique
      getSelfPid >>= register s
      return (ServiceId s)

-- | Start a new remote worker using 'WorkerLauncher' and call a
-- continuation with the 'NodeId' and 'ServiceId' of that worker. The
-- continuation is run in the process that is registered under the
-- 'ServiceId' (see 'withServiceId').
--
-- Throws ('throwM') a 'WorkerConnectionTimeout' if worker times out
-- (timeout described in 'WorkerLauncher')
--
-- The call to the user function is 'bracket'ed by worker startup and
-- shutdown procedures.
withService
  :: Show j
  => WorkerLauncher j
  -> (NodeId -> ServiceId -> Process a)
  -> Process a
withService WorkerLauncher{..} go = withServiceId $ \serviceId -> do
  nid <- getSelfNode
  -- fire up a remote worker with instructions to contact this node
  withLaunchedWorker nid serviceId $ \jobId -> do
    Log.info "Deployed worker" (serviceId, jobId)
    -- Wait for the worker to connect and send its id
    let
      awaitWorker = do
        connectionResult <- case connectionTimeout of
          Just t  -> expectTimeout (nominalDiffTimeToMicroseconds t)
          Nothing -> fmap Just expect
        case connectionResult of
          Nothing -> Log.throw (WorkerConnectionTimeout serviceId)
          Just (workerId :: ProcessId, workerServiceId :: ServiceId, _ :: SendPort WorkerMessage)
            | workerServiceId /= serviceId -> do
                Log.info "Ignoring message from unknown worker" (workerServiceId, jobId, workerId)
                awaitWorker
          Just (workerId :: ProcessId, _ :: ServiceId, replyTo :: SendPort WorkerMessage)
            | otherwise -> do
                Log.info "Acquired worker" (serviceId, jobId, workerId)
                -- Confirm that the worker connected successfully
                sendChan replyTo Connected
                return workerId
      shutdownWorker workerId = do
        Log.info "Worker finished" (serviceId, jobId)
        send workerId ShutDown
    bracket awaitWorker shutdownWorker (\wId -> go (processNodeId wId) serviceId)

-- * Functions related to running remote functions

-- | A process that generates the 'Closure' to be run on a remote machine.
data SerializableClosureProcess a = SerializableClosureProcess
  { -- | Process to generate a closure. This process will be run when
    -- a remote location has been identified that the closure can be
    -- sent to.
    runClosureProcess :: Process (Closure (Process (Either String a)))
    -- | Dict for seralizing the result.
  , staticSDict       :: Closure (SerializableDict (Either String a))
    -- | If a remote computation fails, it may be added to the 'HoldMap'
    -- to be tried again. In that case, we don't want to evaluate
    -- 'runClosureProcess' again, so we use an 'MVar' to memoize the
    -- result of 'runClosureProcess'.
  , closureVar        :: MVar (Closure (Process (Either String a)))
  }

-- | Get closure and memoize the result
getClosure :: SerializableClosureProcess a -> Process (Closure (Process (Either String a)))
getClosure s = do
  whenM (liftIO (isEmptyMVar (closureVar s))) $ do
    c <- runClosureProcess s
    liftIO $ putMVar (closureVar s) c
  liftIO $ readMVar (closureVar s)

-- | The type of a function that takes a 'SerializableClosureProcess'
-- and runs the 'Closure' on a remote machine. In case the remote
-- machine returns a 'Left' value (i.e. an error), throws this value
-- wrapped in 'RemoteError' of type 'RemoteException'. May throw other
-- 'RemoteError's if remote execution fails in any way.
type RemoteProcessRunner =
  forall a . (Binary a, Typeable a) => SerializableClosureProcess a -> Process a

-- | Starts a new remote worker and runs a user function, which is
-- supplied with 'RemoteProcessRunner' for running closures on that
-- worker. If a 'RemoteError' occurs, it is handled by the
-- 'onRemoteError' supplied in the 'WorkerLauncher'.
withRemoteRunProcess
  :: Show j
  => WorkerLauncher j
  -> (RemoteProcessRunner -> Process a)
  -> Process a
withRemoteRunProcess workerLauncher go =
  goWithRemote `catch` \e -> onRemoteError workerLauncher e (withRemoteRunProcess workerLauncher go)
  where
    goWithRemote =
      withService workerLauncher $ \workerNodeId serviceId ->
      go $ \s -> do
      c <- getClosure s
      a <- wait =<< async (task $ call' (staticSDict s) workerNodeId c)
      case a of
        AsyncDone (Right result) -> return result
        -- By throwing an exception out of withService, we ensure that
        -- the offending worker will be sent the ShutDown signal,
        -- since withService uses 'bracket'
        AsyncDone (Left err)     -> throwM $ RemoteError serviceId $ RemoteException err
        AsyncFailed reason       -> throwM $ RemoteError serviceId $ RemoteAsyncFailed reason
        AsyncLinkFailed reason   -> throwM $ RemoteError serviceId $ RemoteAsyncLinkFailed reason
        AsyncCancelled           -> throwM $ RemoteError serviceId $ RemoteAsyncCancelled
        AsyncPending             -> throwM $ RemoteError serviceId $ RemoteAsyncPending

-- | Construct a SerializableClosureProcess for evaluating the closure
-- 'mb' on a remote machine. The action 'mb' that produces the
-- 'Closure' will only be run once -- when a worker first becomes
-- available. The MVar 'v' caches the resulting Closure (so it can be
-- re-used in the event of an error and retry), which will then be
-- sent across the network.
--
-- Note that we wrap the given closure in tryLogException. Thus,
-- exception handling is added by catching any exception @e@, logging
-- @e@ with 'Log.err' (on the worker), and returning a 'Left' result
-- with the textual representation of @e@ from 'Show' instance.
mkSerializableClosureProcess
  :: Typeable b
  => Closure (Dict (Serializable b))
  -> Process (Closure (Process b))
  -> Process (SerializableClosureProcess b)
mkSerializableClosureProcess bDict mb = do
  v <- liftIO newEmptyMVar
  pure $ SerializableClosureProcess
    { runClosureProcess = fmap (static tryLogException `ptrAp`) mb
    , staticSDict       = static (\Dict -> SerializableDict) `ptrAp` bDict
    , closureVar        = v
    }

masterNodeIdLabel :: String
masterNodeIdLabel = "masterNodeIdLabel"

masterNodeIdStatic :: Static (Maybe NodeId)
masterNodeIdStatic = staticLabel masterNodeIdLabel

getMasterNodeId :: Process (Maybe NodeId)
getMasterNodeId = unStatic masterNodeIdStatic

registerMasterNodeId :: Maybe NodeId -> RemoteTable -> RemoteTable
registerMasterNodeId nid = registerStatic masterNodeIdLabel (toDynamic nid)

workerStaticConfigLabel :: String
workerStaticConfigLabel  = "workerStaticConfig"

workerStaticConfigStatic :: Static HyperionStaticConfig
workerStaticConfigStatic = staticLabel workerStaticConfigLabel

getWorkerStaticConfig :: Process HyperionStaticConfig
getWorkerStaticConfig = unStatic workerStaticConfigStatic

registerWorkerStaticConfig :: HyperionStaticConfig -> RemoteTable -> RemoteTable
registerWorkerStaticConfig staticConfig =
  registerStatic workerStaticConfigLabel (toDynamic staticConfig)

initWorkerRemoteTable :: HyperionStaticConfig -> Maybe NodeId -> RemoteTable
initWorkerRemoteTable staticConfig nid =
  registerWorkerStaticConfig staticConfig .
  registerMasterNodeId nid $
  Node.initRemoteTable
