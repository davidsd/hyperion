{-# LANGUAGE DeriveAnyClass      #-}
{-# LANGUAGE DeriveDataTypeable  #-}
{-# LANGUAGE DeriveGeneric       #-}
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
                                                      remoteTask, wait)
import           Control.Distributed.Process.Closure (SerializableDict (..),
                                                      staticDecode)
import qualified Control.Distributed.Process.Node    as Node
import           Control.Distributed.Static          (closure, staticApply,
                                                      staticCompose, staticPtr)
import           Control.Monad.Catch                 (Exception, bracket, catch, try,
                                                      throwM, SomeException)
import           Control.Monad.Extra                 (whenM)
import           Control.Monad.Trans.Maybe           (MaybeT (..))
import           Data.Binary                         (Binary, encode)
import           Data.Data                           (Data, Typeable)
import           Data.Foldable                       (asum)
import           Data.Text                           (Text, pack)
import qualified Data.Text.Encoding                  as E
import           Data.Time.Clock                     (NominalDiffTime)
import           GHC.Generics                        (Generic)
import           GHC.StaticPtr                       (StaticPtr)
import           Hyperion.HoldServer                 (HoldMap,
                                                      blockUntilReleased)
import qualified Hyperion.Log                        as Log
import           Hyperion.Util                       (nominalDiffTimeToMicroseconds,
                                                      randomString)
import           Network.BSD                         (getHostName)
import           Network.Socket                      (ServiceName)
import           Network.Transport                   (EndPointAddress (..))
import           Network.Transport.TCP
import           System.Timeout                      (timeout)

-- * Types

-- | Type for service id. 'ServiceId' is typically a random string that 
-- is assigned to a worker. (Maybe to other things too?)
newtype ServiceId = ServiceId String
  deriving (Eq, Show, Generic, Data, Binary)

serviceIdToText :: ServiceId -> Text
serviceIdToText = pack . serviceIdToString

serviceIdToString :: ServiceId -> String
serviceIdToString (ServiceId s) = s

-- | Type for basic master to worker messaging 
data WorkerMessage = Connected | ShutDown
  deriving (Read, Show, Generic, Data, Binary)

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
    -- | If a 'HoldMap' is present, a remote process that throws an
    -- error will be added to the 'HoldMap'. It can be restarted later
    -- by connecting to the "Hyperion.HoldServer" via 'curl'.
  , serviceHoldMap    :: Maybe HoldMap
  }

-- * Functions for running a worker

-- | 'runProcessLocally' with default 'RemoteTable' and trying ports 
-- @[10090 .. 10990]@. See 'runProcessLocally' and 'runProcessLocally_'.
runProcessLocallyDefault :: Process a -> IO a
runProcessLocallyDefault = runProcessLocally Node.initRemoteTable ports
  where
    ports = map show [10090 .. 10990 :: Int]

-- | Same as 'runProcessLocally_', but returns allows a return value for the 
-- 'Process'.
runProcessLocally :: RemoteTable -> [ServiceName] -> Process a -> IO a
runProcessLocally rtable ports process = do
  resultVar <- newEmptyMVar
  runProcessLocally_ rtable ports $ process >>= liftIO . putMVar resultVar
  takeMVar resultVar

-- | Spawns a new local "Control.Distributed.Process.Node" 
-- with the given 'RemoteTable' and runs the given 'Process'
-- on it. Waits for the process to finish.
--
-- It tries to bind the node to the given list ['ServiceName'] of ports, 
-- attempting them one-by-one, and waiting for 5 seconds before timing the port out.
runProcessLocally_ :: RemoteTable -> [ServiceName] -> Process () -> IO ()
runProcessLocally_ rtable ports process = do
  host  <- getHostName
  let
    tryPort port = MaybeT $
      timeout (5*1000*1000)
      (createTransport host port (\port' -> (host, port')) defaultTCPParameters) >>= \case
      Nothing -> do
        Log.info "Timeout connecting to port" port
        return Nothing
      Just (Left _) -> return Nothing
      Just (Right t) -> return (Just t)
  runMaybeT (asum (map tryPort ports)) >>= \case
    Nothing -> Log.throwError $ "Couldn't bind to ports: " ++ show ports
    Just t -> do
      node <- Node.newLocalNode t rtable
      Log.info "Running on node" (Node.localNodeId node)
      Node.runProcess node process

-- | Convert a 'Text' representation of 'EndPointAddress' to 'NodeId'.
-- The format for the end point address is \"TCP host:TCP port:endpoint id\"
addressToNodeId :: Text -> NodeId
addressToNodeId = NodeId . EndPointAddress . E.encodeUtf8

-- | Inverse to 'addressToNodeId'
nodeIdToAddress :: NodeId -> Text
nodeIdToAddress (NodeId (EndPointAddress addr)) = E.decodeUtf8 addr

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
  self <- getSelfNode
  -- fire up a remote worker with instructions to contact this node
  withLaunchedWorker self serviceId $ \jobId -> do
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
    runClosureProcess :: Process (Closure (Process a))
    -- | Dict for seralizing the result.
  , staticSDict       :: Static (SerializableDict a)
    -- | If a remote computation fails, it may be added to the 'HoldMap'
    -- to be tried again. In that case, we don't want to evaluate
    -- 'runClosureProcess' again, so we use an 'MVar' to memoize the
    -- result of 'runClosureProcess'.
  , closureVar        :: MVar (Closure (Process a))
  }

-- | Get closure and memoize the result
getClosure :: SerializableClosureProcess a -> Process (Closure (Process a))
getClosure s = do
  whenM (liftIO (isEmptyMVar (closureVar s))) $ do
    c <- runClosureProcess s
    liftIO $ putMVar (closureVar s) c
  liftIO $ readMVar (closureVar s)

-- | The type of a function that takes a 'SerializableClosureProcess' and
-- runs the 'Closure' on a remote machine. In case the remote machine returns
-- a 'Left' value (i.e. an error), throws this value wrapped in 'RemoteError'
-- of type 'RemoteException'. May throw other 'RemoteError's if remote execution 
-- fails in any way.
type RemoteProcessRunner =
  forall a . (Binary a, Typeable a) => SerializableClosureProcess (Either String a) -> Process a

-- | Starts a new remote worker and runs a user function, which is 
-- supplied with 'RemoteProcessRunner' for running
-- closures on that worker. If 'WorkerLauncher' has a 'HoldMap', then
-- 'RemoteError' exceptions propagating out of the supplied user function
-- are logged and 'withRemoteRunProcess' blocks until the 'ServiceId' is released 
-- by 'HoldServer'. Then 'withRemoteRunProcess' restarts (generating new 'ServiceId').
-- If no 'HoldMap' is available, then the exception propagates out of 'withRemoteRunProcess'.
withRemoteRunProcess
  :: Show j
  => WorkerLauncher j
  -> (RemoteProcessRunner -> Process a)
  -> Process a
withRemoteRunProcess workerLauncher go =
  catch goWithRemote $ \e@(RemoteError sId _) -> do
  case serviceHoldMap workerLauncher of
    Just holdMap -> do
      -- In the event of an error, add the offending serviceId to the
      -- HoldMap. We then block until someone releases the service by
      -- sending a request to the HoldServer.
      Log.err e
      Log.info "Remote process failed; initiating hold" sId
      blockUntilReleased holdMap (serviceIdToText sId)
      Log.info "Hold released; retrying" sId
      withRemoteRunProcess workerLauncher go
    -- If there is no HoldMap, just rethrow the exception
    Nothing -> throwM e
  where
    goWithRemote =
      withService workerLauncher $ \workerNodeId serviceId ->
      go $ \s -> do
      c <- getClosure s
      a <- wait =<< async (remoteTask (staticSDict s) workerNodeId c)
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

-- | A monadic function, together with SerializableDicts for its input
-- and output. In the output type 'Either String b', String represents
-- an error in remote execution.
data RemoteFunction a b = RemoteFunction
  { remoteFunctionRun :: a -> Process (Either String b)
  , sDictIn           :: SerializableDict a
  , sDictOut          :: SerializableDict (Either String b)
  }

-- | Produces a 'RemoteFunction' from a monadic function. Exception handling is added
-- by catching any exception @e@, logging @e@ with 'Log.err' (on the worker), 
-- and returning a 'Left' result with the textual representation of @e@ from 
-- 'Show' instance.
remoteFn
  :: (Binary a, Typeable a, Binary b, Typeable b)
  => (a -> Process b)
  -> RemoteFunction a b
remoteFn f = RemoteFunction f' SerializableDict SerializableDict
  where
    -- Catch any exception, log it, and return as a string. In this
    -- way, errors will be logged by the worker where they occurred,
    -- and also sent up the tree.
    f' a = try (f a) >>= \case
      Left (e :: SomeException) -> do
        Log.err e
        return (Left (show e))
      Right b ->
        return (Right b)

-- | Same as 'remoteFn' but takes a function in 'IO' monad.
remoteFnIO
  :: (Binary a, Typeable a, Binary b, Typeable b)
  => (a -> IO b)
  -> RemoteFunction a b
remoteFnIO f = remoteFn (liftIO . f)

-- | 'remoteFunctionRun' of 'RemoteFunction' wrapped in 'Static'.
remoteFunctionRunStatic
  :: (Typeable a, Typeable b)
  => Static (RemoteFunction a b -> a -> Process (Either String b))
remoteFunctionRunStatic = staticPtr (static remoteFunctionRun)

-- | 'sDictIn' of 'RemoteFunction' wrapped in 'Static'.
sDictInStatic
  :: (Typeable a, Typeable b)
  => Static (RemoteFunction a b -> SerializableDict a)
sDictInStatic = staticPtr (static sDictIn)

-- | 'sDictOut' of 'RemoteFunction' wrapped in 'Static'.
sDictOutStatic
  :: (Typeable a, Typeable b)
  => Static (RemoteFunction a b -> SerializableDict (Either String b))
sDictOutStatic = staticPtr (static sDictOut)

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
bindRemoteStatic
  :: (Binary a, Typeable a, Typeable b)
  => Process a
  -> StaticPtr (RemoteFunction a b)
  -> Process (SerializableClosureProcess (Either String b))
bindRemoteStatic ma kRemotePtr = do
  v <- liftIO newEmptyMVar
  return SerializableClosureProcess
    { runClosureProcess = closureProcess
    , staticSDict       = bDict
    , closureVar        = v
    }
  where
    closureProcess = do
      a <- ma
      return $ closure (f `staticCompose` staticDecode aDict) (encode a)
    s     = staticPtr kRemotePtr
    f     = remoteFunctionRunStatic `staticApply` s
    aDict = sDictInStatic  `staticApply` s
    bDict = sDictOutStatic `staticApply` s

-- | Same as 'bindRemoteStatic' where the argument to 'RemoteFunction' is 
-- constructed by 'return' from the supplied argument.
applyRemoteStatic
  :: (Binary a, Typeable a, Typeable b)
  => StaticPtr (RemoteFunction a b)
  -> a
  -> Process (SerializableClosureProcess (Either String b))
applyRemoteStatic k a = return a `bindRemoteStatic` k
