{-# LANGUAGE DeriveAnyClass      #-}
{-# LANGUAGE DerivingStrategies  #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE StaticPointers      #-}

module Hyperion.Remote
  ( runProcessLocal
  , runProcessLocalWithRT
  , HostNameStrategy(..)
  , defaultHostNameStrategy
  , useSubnet
  , Subnet(..)
  , addressToNodeId
  , nodeIdToAddress
  ) where

import Control.Concurrent.MVar          (newEmptyMVar, putMVar, takeMVar)
import Control.Distributed.Process      hiding (bracket, catch, try)
import Control.Distributed.Process.Node qualified as Node
import Control.Monad.Catch              (Exception)
import Data.Bits                        ((.&.))
import Data.Text                        (Text)
import Data.Text.Encoding               qualified as E
import Data.Word                        (Word8)
import Hyperion.Log                     qualified as Log
import Network.BSD                      (HostEntry (..), getHostEntries,
                                         getHostName)
import Network.Info                     (IPv4 (..), NetworkInterface (..),
                                         getNetworkInterfaces)
import Network.Socket                   (HostAddress, hostAddressToTuple,
                                         tupleToHostAddress)
import Network.Transport                (EndPointAddress (..))
import Network.Transport.TCP            qualified as NT

-- * Types

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
isAddressInSubnet subnet address = (bits .&. maskbits) == (address .&. maskbits)
  where
    bits = tupleToHostAddress subnet.subnetAddress
    maskbits = tupleToHostAddress subnet.subnetMask

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
data HostNameStrategy
  = GetHostName
  | GetHostEntriesExternal
  | InterfaceSelector ([NetworkInterface] -> IO NetworkInterface)

-- | The default strategy is 'HostNameStrategy'
defaultHostNameStrategy :: HostNameStrategy
defaultHostNameStrategy = GetHostName

-- | 'HostNameStrategy' which selects the first interface whose address satisfies
-- a given filter function
interfaceFilter :: (HostAddress -> Bool) -> HostNameStrategy
interfaceFilter f = InterfaceSelector $ \interfaces -> case filter (f . interfaceAddress) interfaces of
  ni:_ -> return ni
  [] -> Log.throw (HostInterfaceError "Couldn't find a suitable network interface." $ interfaces)

-- | 'HostNameStrategy' which selects the first interface whose address belongs to a given subnet
useSubnet :: Subnet -> HostNameStrategy
useSubnet subnet = interfaceFilter (isAddressInSubnet subnet)

-- | Returns the 'HostAddress' for a given network interface
interfaceAddress :: NetworkInterface -> HostAddress
interfaceAddress ni = toHostAddress $ ipv4 ni
  where
    toHostAddress (IPv4 n) = n


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
