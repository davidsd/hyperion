{-# LANGUAGE CPP                #-}
{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase         #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE RecordWildCards    #-}
{-# LANGUAGE StaticPointers     #-}

module Hyperion.Remote where

import Control.Concurrent.MVar             (MVar, isEmptyMVar, newEmptyMVar,
                                            putMVar, readMVar, takeMVar)
import Control.Distributed.Process         hiding (bracket, catch, try)
import Control.Distributed.Process.Async   (AsyncResult (..), async, task, wait)
import Control.Distributed.Process.Closure (SerializableDict (..))
import Control.Distributed.Process.Node    qualified as Node
import Control.Monad.Catch                 (Exception, MonadCatch,
                                            SomeException, bracket, catch,
                                            throwM, try)
import Control.Monad.Extra                 (whenM)
import Control.Monad.IO.Class              (MonadIO)
import Data.Binary                         (Binary)
import Data.Bits                           ((.&.))
import Data.Constraint                     (Dict (..))
import Data.Data                           (Typeable)
import Data.Text                           (Text, pack)
import Data.Text.Encoding                  qualified as E
import Data.Time.Clock                     (NominalDiffTime)
import Data.Word                           (Word8)
import GHC.Generics                        (Generic)
import Hyperion.CallClosure                (call')
import Hyperion.Log                        qualified as Log
import Hyperion.Static                     (Serializable, ptrAp)
import Hyperion.Util                       (newUnique,
                                            nominalDiffTimeToMicroseconds)
import Network.BSD                         (HostEntry (..), getHostEntries,
                                            getHostName)
import Network.Info                        (IPv4 (..), NetworkInterface (..),
                                            getNetworkInterfaces)
import Network.Socket                      (HostAddress, hostAddressToTuple,
                                            tupleToHostAddress)
import Network.Transport                   (EndPointAddress (..))
import Network.Transport.TCP               qualified as NT

-- * Types

-- | Type for service id. 'ServiceId' is typically a random string that
-- is assigned to a worker. (Maybe to other things too?)
newtype ServiceId = ServiceId String
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Binary)

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

-- * Host name strategies
-- In order to start 'Process'es, we need to provide a hostname. Unfortunately,
-- this hostname plays two roles: first, it is used to determine on which 
-- network interface we will listen, but also determines the address for our 
-- 'Node' that we can get from 'getSelfNode'.
--
-- The simplest option would be to use the wildcard IPv4 0.0.0.0 which would
-- make us listen on all network interfaces. However, this then makes our node
-- address 0.0.0.0:... which we then advertise to workers, which doesn't work.
--
-- This means that we need a strategy for selecting a correct network interface.

-- | A type synonim for IPv4 address
type IPv4AsTuple = (Word8, Word8, Word8, Word8)

-- | A basic subnet description -- a mask and an IPv4 address. An IPv4 address
-- is considered to be in the subnet if it agrees with the subnet address in all
-- bits which are set in the mask.
data Subnet = Subnet
  { -- using tuples since this is user-facing
    subnetMask    :: IPv4AsTuple,
    subnetAddress :: IPv4AsTuple
  }

isAddressInSubnet :: Subnet -> HostAddress -> Bool
isAddressInSubnet Subnet{..} address = (bits .&. maskbits) == (address .&. maskbits)
  where
    bits = tupleToHostAddress subnetAddress
    maskbits = tupleToHostAddress subnetMask

data HostInterfaceError = HostInterfaceError String [NetworkInterface]
  deriving (Show, Exception)

-- | Datatype describing various strategies for selecting the hostname.
-- 
-- * 'GetHostName' will use 'getHostName' function. This works fine in most cases
--   but relies on DNS lookup to give us the ip address for the correct network 
--   interface.
-- * 'GetHostEntriesExternal' will use 'getHostEntries' to obtain a list of hostnames
--   and will try to find one which is not of the type 127.*.*.* or 10.*.*.*.
-- * 'InterfaceSelector' uses a user-provide function to select an interface from
--   the list of all network interfaces.
data HostNameStrategy = GetHostName | GetHostEntriesExternal | InterfaceSelector ([NetworkInterface] -> IO NetworkInterface)

-- | The default strategy is 'HostNameStrategy'
defaultHostNameStrategy :: HostNameStrategy
defaultHostNameStrategy = GetHostName

-- | Returns the 'HostAddress' for a given network interface
interfaceAddress :: NetworkInterface -> HostAddress
interfaceAddress ni = toHostAddress $ ipv4 ni
  where
    toHostAddress (IPv4 n) = n

-- | 'HostNameStrategy' which selects the first interface whose address satisfies
-- a given filter function
interfaceFilter :: (HostAddress -> Bool) -> HostNameStrategy
interfaceFilter f = InterfaceSelector $ \interfaces -> case filter (f . interfaceAddress) interfaces of
  ni:_ -> return ni
  [] -> Log.throw (HostInterfaceError "Couldn't find a suitable network interface." $ interfaces)

-- | 'HostNameStrategy' which selects the first interface whose address belongs to a given subnet
useSubnet :: Subnet -> HostNameStrategy
useSubnet subnet = interfaceFilter (isAddressInSubnet subnet)

-- | Find a hostname based on the 'HostNameStrategy'. The result is a string representing
-- either a hostname or an IPv4 address. Throws if a suitable interface cannot be found.
findHostName :: HostNameStrategy -> IO String
findHostName GetHostName            = getHostName
findHostName GetHostEntriesExternal = getHostEntriesExternal
findHostName (InterfaceSelector selector) = do
  interfaces <- getNetworkInterfaces
  interface <- selector interfaces
  return . ipString . hostAddressToTuple $ interfaceAddress interface
  where
    ipString (a, b, c, d) = (show a) ++ "." ++ (show b) ++ "." ++ (show c) ++ "." ++ (show d)

-- | Get a hostname for the current machine that does not correspond
-- to a local network address (127.* or 10.*). Uses 'getHostEntries'.
getHostEntriesExternal :: IO String
getHostEntriesExternal = do
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

-- * Functions for running a worker

-- | Run a Process locally using the default
-- 'RemoteTable'. Additionally allows a return value for the
-- 'Process'.
runProcessLocal :: HostNameStrategy -> Process a -> IO a
runProcessLocal s = runProcessLocalWithRT s Node.initRemoteTable

-- | Run a Process locally using the specified
-- 'RemoteTable'. Additionally allows a return value for the
-- 'Process'.
runProcessLocalWithRT :: HostNameStrategy -> RemoteTable -> Process a -> IO a
runProcessLocalWithRT s rt process = do
  resultVar <- newEmptyMVar
  runProcessLocalWithRT_ s rt $ process >>= liftIO . putMVar resultVar
  takeMVar resultVar

-- | Spawns a new local "Control.Distributed.Process.Node" and runs
-- the given 'Process' on it. Waits for the process to finish.
--
-- Binds to the first available port by specifying port 0.
--
-- NOTE: Some clusters, for example XSEDE's expanse cluster, cannot
-- communicate between nodes using the output of 'getHostName'. In
-- such cases, one can try building with the flag
-- 'USE_EXTERNAL_HOSTNAME' which returns a different address.
runProcessLocalWithRT_ :: HostNameStrategy -> RemoteTable -> Process () -> IO ()
runProcessLocalWithRT_ strategy rtable process = do
  host <- findHostName strategy
  NT.createTransport (NT.defaultTCPAddr host "0") NT.defaultTCPParameters >>= \case
    Left e -> Log.throw e
    Right t -> do
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

-- | Registers ('register') the current process under a random 'ServiceId', then
-- passes the 'ServiceId' to the given continuation.
-- After the continuation returns, unregisters ('unregister') the 'ServiceId'.
withServiceId :: (ServiceId -> Process a) -> Process a
withServiceId = bracket newServiceId (\(ServiceId s) -> unregister s)
  where
    newServiceId = do
      s <- liftIO $ show <$> newUnique
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
tryLogException :: (MonadCatch m, MonadIO m) => m b -> m (Either String b)
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
