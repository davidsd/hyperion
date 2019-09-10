{-# LANGUAGE DeriveAnyClass      #-}
{-# LANGUAGE DeriveDataTypeable  #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
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
import           Control.Distributed.Static          (closure, registerStatic,
                                                      staticApply,
                                                      staticCompose,
                                                      staticLabel, staticPtr)
import           Control.Monad.Catch                 (Exception, bracket, catch,
                                                      throwM)
import           Control.Monad.Extra                 (whenM)
import           Control.Monad.Trans.Maybe           (MaybeT (..))
import           Data.Binary                         (Binary, encode)
import           Data.Data                           (Data, Typeable)
import           Data.Foldable                       (asum)
import           Data.Rank1Dynamic                   (toDynamic)
import           Data.Rank1Typeable                  (ANY1, ANY2)
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

newtype ServiceId = ServiceId String
  deriving (Eq, Show, Generic, Data, Binary)

serviceIdToText :: ServiceId -> Text
serviceIdToText = pack . serviceIdToString

serviceIdToString :: ServiceId -> String
serviceIdToString (ServiceId s) = s

data WorkerMessage = Connected | ShutDown
  deriving (Read, Show, Generic, Data, Binary)

data RemoteAsyncError = RemoteAsyncError ServiceId RemoteAsyncErrorType
  deriving (Show, Exception)

data RemoteAsyncErrorType
  = RemoteAsyncFailed DiedReason
  | RemoteAsyncLinkFailed DiedReason
  | RemoteAsyncCancelled
  | RemoteAsyncPending
  deriving (Show)

data WorkerConnectionTimeout = WorkerConnectionTimeout ServiceId
  deriving (Show, Exception)

data WorkerLauncher j = WorkerLauncher
  { -- A function that launches a worker for the given ServiceId on
    -- the master NodeId and supplies its JobId to the given
    -- continuation
    withLaunchedWorker :: forall b . NodeId -> ServiceId -> (j -> Process b) -> Process b
    -- Timeout for the worker to connect. If the worker is launched
    -- into a Slurm queue, it may take a very long time to connect. In
    -- that case, it is recommended to set connectionTimeout =
    -- Nothing.
  , connectionTimeout :: Maybe NominalDiffTime
  , serviceHoldMap    :: Maybe HoldMap
  }

addFstSndStatic :: RemoteTable -> RemoteTable
addFstSndStatic =
  registerStatic "$fst" (toDynamic (fst :: (ANY1, ANY2) -> ANY1)) .
  registerStatic "$snd" (toDynamic (snd :: (ANY1, ANY2) -> ANY2))

fstStatic :: Static ((a,b) -> a)
fstStatic = staticLabel "$fst"

sndStatic :: Static ((a,b) -> b)
sndStatic = staticLabel "$snd"

runProcessLocallyDefault :: Process a -> IO a
runProcessLocallyDefault = runProcessLocally Node.initRemoteTable ports
  where
    ports = map show [10090 .. 10990 :: Int]

runProcessLocally :: RemoteTable -> [ServiceName] -> Process a -> IO a
runProcessLocally rtable ports process = do
  resultVar <- newEmptyMVar
  runProcessLocally_ rtable ports $ process >>= liftIO . putMVar resultVar
  takeMVar resultVar

runProcessLocally_ :: RemoteTable -> [ServiceName] -> Process () -> IO ()
runProcessLocally_ rtable' ports process = do
  host  <- getHostName
  let
    rtable = addFstSndStatic rtable'
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

addressToNodeId :: Text -> NodeId
addressToNodeId = NodeId . EndPointAddress . E.encodeUtf8

nodeIdToAddress :: NodeId -> Text
nodeIdToAddress (NodeId (EndPointAddress addr)) = E.decodeUtf8 addr

-- | Repeatedly send our own nodeId to a masterNode until it replies
-- 'Connected'.  Then wait for a 'ShutDown' signal.  While waiting,
-- other processes will be run in a different thread.
worker :: NodeId -> ServiceId -> Process ()
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

withServiceId :: (ServiceId -> Process a) -> Process a
withServiceId = bracket newServiceId (\(ServiceId s) -> unregister s)
  where
    newServiceId = do
      s <- liftIO $ randomString 5
      getSelfPid >>= register s
      return (ServiceId s)

-- | Start a new remote worker and call go with the NodeId of that
-- worker
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
    -- Wait for a worker to connect and send its id
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

-- | A process that generates the Closure to be run on a remote machine.
data SerializableClosureProcess a = SerializableClosureProcess
  { -- | Process to generate closure
    runClosureProcess :: Process (Closure (Process a))
    -- | Dict for seralizing result
  , staticSDict       :: Static (SerializableDict a)
    -- | MVar for memoizing closure so we don't run process more than once
  , closureVar        :: MVar (Closure (Process a))
  }

-- | Get closure and memoize the result
getClosure :: SerializableClosureProcess a -> Process (Closure (Process a))
getClosure s = do
  whenM (liftIO (isEmptyMVar (closureVar s))) $ do
    c <- runClosureProcess s
    liftIO $ putMVar (closureVar s) c
  liftIO $ readMVar (closureVar s)

-- | The type of a function that takes a SerializableClosureProcess and
-- runs the Closure on a remote machine.
type RemoteProcessRunner = forall a . (Binary a, Typeable a) => SerializableClosureProcess a -> Process a

-- | A monadic function, together with SerializableDicts for its input
-- and output
type RemoteFunction a b = (a -> Process b, (SerializableDict a, SerializableDict b))

-- | Start a new remote worker and provide a function for running
-- closures on that worker.
withRemoteRunProcess
  :: Show j
  => WorkerLauncher j
  -> (RemoteProcessRunner -> Process a)
  -> Process a
withRemoteRunProcess workerLauncher go =
  catch goWithRemote $ \e@(RemoteAsyncError sId _) -> do
  case serviceHoldMap workerLauncher of
    Just holdMap -> do
      -- In the event of an error, add the offending serviceId to the
      -- HoldMap. We then block until someone releases the service by
      -- sending a request to the HoldServer.
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
        AsyncDone r       -> return r
        AsyncFailed r     -> Log.throw $ RemoteAsyncError serviceId $ RemoteAsyncFailed r
        AsyncLinkFailed r -> Log.throw $ RemoteAsyncError serviceId $ RemoteAsyncLinkFailed r
        AsyncCancelled    -> Log.throw $ RemoteAsyncError serviceId $ RemoteAsyncCancelled
        AsyncPending      -> Log.throw $ RemoteAsyncError serviceId $ RemoteAsyncPending

bindRemoteStatic
  :: (Binary a, Typeable a, Typeable b)
  => Process a
  -> StaticPtr (RemoteFunction a b)
  -> Process (SerializableClosureProcess b)
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
    f     = fstStatic `staticApply` s
    aDict = fstStatic `staticApply` (sndStatic `staticApply` s)
    bDict = sndStatic `staticApply` (sndStatic `staticApply` s)

applyRemoteStatic
  :: (Binary a, Typeable a, Typeable b)
  => StaticPtr (RemoteFunction a b)
  -> a
  -> Process (SerializableClosureProcess b)
applyRemoteStatic k a = return a `bindRemoteStatic` k

remoteFn
  :: (Binary a, Typeable a, Binary b, Typeable b)
  => (a -> Process b)
  -> RemoteFunction a b
remoteFn f = (f, (SerializableDict, SerializableDict))

remoteFnIO
  :: (Binary a, Typeable a, Binary b, Typeable b)
  => (a -> IO b)
  -> RemoteFunction a b
remoteFnIO f = remoteFn (liftIO . f)
