{-# LANGUAGE DeriveAnyClass      #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StaticPointers      #-}
{-# LANGUAGE TypeApplications    #-}

module Hyperion.Remote where

import           Control.Concurrent.MVar             (MVar, isEmptyMVar,
                                                      newEmptyMVar, putMVar,
                                                      readMVar, takeMVar)
import           Control.Distributed.Process         hiding (bracket, catch,
                                                      try)
import           Control.Distributed.Process.Async   (AsyncResult (..), async,
                                                      task, wait)
import           Control.Distributed.Process.Closure (SerializableDict (..))
import qualified Control.Distributed.Process.Node    as Node
import           Control.Distributed.Static          (registerStatic,
                                                      staticLabel)
import           Control.Monad.Catch                 (Exception, SomeException,
                                                      bracket, catch, throwM,
                                                      try)
import           Control.Monad.Extra                 (whenM)
import           Control.Monad.Trans.Maybe           (MaybeT (..))
import           Data.Binary                         (Binary)
import           Data.Constraint                     (Dict (..))
import           Data.Data                           (Typeable)
import           Data.Foldable                       (asum)
import           Data.Rank1Dynamic                   (toDynamic)
import           Data.Text                           (Text, pack)
import qualified Data.Text.Encoding                  as E
import           Data.Time.Clock                     (NominalDiffTime)
import           GHC.Generics                        (Generic)
import           GHC.StaticPtr                       (StaticPtr)
import           Hyperion.CallClosure                (call')
import           Hyperion.Closure                    (Serializable, cAp, cPtr,
                                                      cPure', ptrAp)
import qualified Hyperion.Log                        as Log
import           Hyperion.Util                       (nominalDiffTimeToMicroseconds,
                                                      randomString)
import           Network.BSD                         (HostEntry (..),
                                                      getHostEntries,
                                                      getHostName)
import           Network.Socket                      (hostAddressToTuple)
import           Network.Transport                   (EndPointAddress (..))
import qualified Network.Transport.TCP               as NT

-- * Types

-- | Type for service id. 'ServiceId' is typically a random string that
-- is assigned to a worker. (Maybe to other things too?)
newtype ServiceId = ServiceId String
  deriving (Eq, Show, Generic, Binary)

serviceIdToText :: ServiceId -> Text
serviceIdToText = pack . serviceIdToString

serviceIdToString :: ServiceId -> String
serviceIdToString (ServiceId s) = s

-- | Type for basic master to worker messaging
data WorkerMessage = Connected | ShutDown
  deriving (Read, Show, Generic, Binary)

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

-- * Functions for running a worker

-- | Run a Process locally using the default
-- 'RemoteTable'. Additionally allows a return value for the
-- 'Process'.
runProcessLocal :: Process a -> IO a
runProcessLocal = runProcessLocalWithRT Node.initRemoteTable

-- | Run a Process locally using the specified
-- 'RemoteTable'. Additionally allows a return value for the
-- 'Process'.
runProcessLocalWithRT :: RemoteTable -> Process a -> IO a
runProcessLocalWithRT rt process = do
  resultVar <- newEmptyMVar
  runProcessLocalWithRT_ rt $ process >>= liftIO . putMVar resultVar
  takeMVar resultVar

-- | Spawns a new local "Control.Distributed.Process.Node" and runs
-- the given 'Process' on it. Waits for the process to finish.
--
-- Binds to the first available port by specifying port 0.
runProcessLocalWithRT_ :: RemoteTable -> Process () -> IO ()
runProcessLocalWithRT_ rtable process = do
  host <- getHostName
  --host <- getExternalHostName
  NT.createTransport (NT.defaultTCPAddr host "0") NT.defaultTCPParameters >>= \case
    Left e -> Log.throw e
    Right t -> do
      node <- Node.newLocalNode t rtable
      Log.info "Running on node" (Node.localNodeId node)
      Node.runProcess node process

-- | Get a hostname for the current machine that does not correspond
-- to a local network address (127.* or 10.*)
getExternalHostName :: IO String
getExternalHostName = do
  -- TODO: Here 'stayopen' is set to True. Is this an ok choice?
  entries <- getHostEntries True
  case filter (any (not . isLocal) . hostAddresses) entries of
    e : _ -> return $ hostName e
    []    -> Log.throwError $ "Cannot find external network address among host entries: " ++ show entries
  where
    isLocal a = case hostAddressToTuple a of
      (127, _, _, _) -> True
      (10,  _, _, _) -> True
      _              -> False

-- | Convert a 'Text' representation of 'EndPointAddress' to 'NodeId'.
-- The format for the end point address is \"TCP host:TCP port:endpoint id\"
addressToNodeId :: Text -> NodeId
addressToNodeId = NodeId . EndPointAddress . E.encodeUtf8

-- | Inverse to 'addressToNodeId'
nodeIdToAddress :: NodeId -> Text
nodeIdToAddress (NodeId (EndPointAddress addr)) = E.decodeUtf8 addr

masterNodeIdLabel :: String
masterNodeIdLabel = "masterNodeIdLabel"

masterNodeIdStatic :: Static (Maybe NodeId)
masterNodeIdStatic = staticLabel masterNodeIdLabel

getMasterNodeId :: Process (Maybe NodeId)
getMasterNodeId = unStatic masterNodeIdStatic

registerMasterNodeId :: Maybe NodeId -> RemoteTable -> RemoteTable
registerMasterNodeId nid = registerStatic masterNodeIdLabel (toDynamic nid)

initWorkerRemoteTable :: Maybe NodeId -> RemoteTable
initWorkerRemoteTable nid = registerMasterNodeId nid Node.initRemoteTable

-- | The main worker process.
--
-- Repeatedly (at most 5 times) send our own 'ProcessId' and the send end of a typed channel
-- ('SendPort' 'WorkerMessage') to a master node until it replies
-- 'Connected' (timeout 10 seconds for each attempt).
-- Then 'expect' a 'ShutDown' signal.
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

-- | Registers ('register') the current process under a random 'ServiceId', then
-- passes the 'ServiceId' to the given continuation.
-- After the continuation returns, unregisters ('unregister') the 'ServiceId'.
withServiceId :: (ServiceId -> Process a) -> Process a
withServiceId = bracket newServiceId (\(ServiceId s) -> unregister s)
  where
    newServiceId = do
      s <- liftIO $ randomString 5
      getSelfPid >>= register s
      return (ServiceId s)

-- | Start a new remote worker using 'WorkerLauncher' and call a continuation
-- with the 'NodeId' and 'ServiceId' of that worker. The continuation is
-- run in the process that is registered under the 'ServiceId' (see 'withServiceId').
--
-- Throws ('throwM') a 'WorkerConnectionTimeout' if worker times out (timeout
-- described in 'WorkerLauncher')
--
-- The call to the user function is 'bracket'ed by worker startup and shutdown
-- procedures.
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

-- | Catch any exception, log it, and return as a string. In this
-- way, errors will be logged by the worker where they occurred,
-- and also sent up the tree.
tryLogException :: Process b -> Process (Either String b)
tryLogException go = try go >>= \case
  Left (e :: SomeException) -> do
    Log.err e
    return (Left (show e))
  Right b ->
    return (Right b)

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

-- | A monadic function, together with 'Dict (Serializable a)' for its
-- input and output. Constructing a 'RemoteFunction' via 'static
-- (remoteFn f)' is useful when 'a' and 'b' are known at compile time.
data RemoteFunction a b = RemoteFunction
  { remoteFunctionRun :: a -> Process b
  , sDictIn           :: Dict (Serializable a)
  , sDictOut          :: Dict (Serializable b)
  }

-- | Produces a 'RemoteFunction' from a monadic function.
remoteFn :: (Serializable a, Serializable b) => (a -> Process b) -> RemoteFunction a b
remoteFn f = RemoteFunction f Dict Dict

-- | Same as 'remoteFn' but takes a function in 'IO' monad.
remoteFnIO :: (Serializable a, Serializable b) => (a -> IO b) -> RemoteFunction a b
remoteFnIO f = remoteFn (liftIO . f)

-- | Constructs 'SerializableClosureProcess' given an action that constructs
-- the argument to the 'RemoteFunction', and a 'StaticPtr' to the remote function.
-- The action that constructs the argument is embedded into 'runClosureProcess'
-- of the resulting 'SerializableClosureProcess'.
--
-- 'StaticPtr' to the remote function can be constructed by using the keyword 'static'
-- from @StaticPointers@ extention. E.g.,
--
-- > static $ remoteFn f
--
-- Note, however, that @f@ should be either a top-level definition or a closed
-- local definition in order for 'static' to work. Closed local definitions are
-- local definitions that could in principle be defined at top-level.
-- A necessary condition is that the whole object to which 'static' is applied
-- to is known at compile time.
--
-- To work with values that are not known at compile time, see
-- 'Hyperion.HasWorkers.remoteClosure' and
-- 'Hyperion.HasWorkers.StaticConstraint'
bindRemoteStatic
  :: forall a b . (Typeable a, Binary a, Typeable b)
  => Process a
  -> StaticPtr (RemoteFunction a b)
  -> Process (SerializableClosureProcess b)
bindRemoteStatic ma f =
  mkSerializableClosureProcess bDict $
  cAp fStatic . cPure' aDict <$> ma
  where
    fStatic = static remoteFunctionRun `ptrAp` cPtr f
    aDict = static sDictIn  `ptrAp` cPtr f
    bDict = static sDictOut `ptrAp` cPtr f

-- | Same as 'bindRemoteStatic' where the argument to 'RemoteFunction' is
-- constructed by 'pure' from the supplied argument.
applyRemoteStatic
  :: forall a b . (Typeable a, Binary a, Typeable b)
  => StaticPtr (RemoteFunction a b)
  -> a
  -> Process (SerializableClosureProcess b)
applyRemoteStatic f a = pure a `bindRemoteStatic` f
