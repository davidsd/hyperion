{-# LANGUAGE DeriveAnyClass      #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE PolyKinds           #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeFamilies        #-}

-- | An 'ExtVar' is an 'MVar' that can be accessed by an external
-- client. The "host" is the machine where the underlying 'MVar'
-- exists. The host can continue to use the underlying 'MVar' as
-- usual. A client can interact with it via functions like
-- 'takeExtVar', 'putExtVar', 'readExtVar', etc., which behave in the
-- same way as their 'MVar' counterparts. An 'ExtVar' can be
-- recontstructed from its representation as a String or serialized
-- to/from Binary data (and hence sent across a network).
--
-- For an example of using an 'ExtVar' as a client, look in the hosts
-- logs for a line that looks like:
--
-- > [Thu 01/06/22 13:04:17] Made ExtVar: extVar @Int "login1.cm.cluster:39443:0" "test"
--
-- This shows that the host machine has made an ExtVar and it is ready
-- to be accessed by a client.  Now in a GHCi session (possibly on a
-- completely different machine), you can do:
--
-- >>> eVar = extVar @Int "login1.cm.cluster:39443:0" "test"
-- >>> tryReadExtVarIO eVar
-- Just 42
-- >>> modifyExtVarIO_ eVar (\x -> pure (x+1))
-- ()
-- >>> tryReadExtVarIO eVar
-- Just 43
--
module Hyperion.ExtVar
  ( ExtVar
  , extVar
  , newExtVar
  , killExtVar
  , takeExtVar
  , tryTakeExtVar
  , putExtVar
  , tryPutExtVar
  , readExtVar
  , tryReadExtVar
  , withExtVar
  , modifyExtVar_
  , modifyExtVar
  , takeExtVarIO
  , tryTakeExtVarIO
  , putExtVarIO
  , tryPutExtVarIO
  , readExtVarIO
  , tryReadExtVarIO
  , withExtVarIO
  , modifyExtVarIO_
  , modifyExtVarIO
  ) where

import           Control.Concurrent.MVar     (MVar, putMVar, readMVar, takeMVar,
                                              tryPutMVar, tryReadMVar,
                                              tryTakeMVar)
import           Control.Distributed.Process (NodeId (..), Process, SendPort,
                                              expect, getSelfPid, liftIO,
                                              newChan, nsendRemote,
                                              processNodeId, receiveChan,
                                              register, sendChan, spawnLocal)
import           Control.Monad               (void)
import           Control.Monad.Catch         (bracket, mask, onException)
import           Data.Binary                 (Binary)
import           Data.ByteString             (ByteString)
import           GHC.Generics                (Generic)
import qualified Hyperion.Log                as Log
import           Hyperion.Remote             (runProcessLocal)
import           Network.Transport           (EndPointAddress (..))
import           Type.Reflection             (Typeable, typeRep)

data ExtVar a = MkExtVar NodeId String
  deriving (Eq, Ord, Generic, Binary)

instance Typeable a => Show (ExtVar a) where
  showsPrec d (MkExtVar (NodeId (EndPointAddress address)) name) =
    showParen (d > 10) $
    showString "extVar @" .
    showsPrec 11 (typeRep @a) .
    showChar ' ' .
    shows address .
    showChar ' ' .
    shows name

-- | 'ExtVar' from an address and a name. To see what arguments you
-- should pass to 'extVar', it is best to look for the "Made ExtVar"
-- entry in the log o the host machine.
extVar
  :: ByteString -- ^ End point address. 
  -> String     -- ^ Name of the ExtVar
  -> ExtVar a
extVar address name = MkExtVar (NodeId $ EndPointAddress address) name

data ExtVarMessage a
  = Take     (SendPort a)
  | TryTake  (SendPort (Maybe a))
  | Put    a (SendPort ())
  | TryPut a (SendPort Bool)
  | Read     (SendPort a)
  | TryRead  (SendPort (Maybe a))
  | Shutdown
  deriving (Generic, Binary)

extVarServer :: (Typeable a, Binary a) => String -> MVar a -> Process ()
extVarServer name var = do
  getSelfPid >>= register name
  go
  where
    forClient :: (Typeable a, Binary a) => SendPort a -> IO a -> Process ()
    forClient client run = do
      void $ spawnLocal $ liftIO run >>= sendChan client
      go
    go = expect >>= \case
      Take c            -> forClient c $ takeMVar var
      TryTake c         -> forClient c $ tryTakeMVar var
      Put contents c    -> forClient c $ putMVar var contents
      TryPut contents c -> forClient c $ tryPutMVar var contents
      Read c            -> forClient c $ readMVar var
      TryRead c         -> forClient c $ tryReadMVar var
      Shutdown          -> pure ()

-- | Make a new 'ExtVar' from an 'MVar', together with a name. The
-- host program can continue to use the 'MVar' as usual. If the name
-- is not unique, a 'ProcessRegistrationException' will be thrown.
newExtVar :: (Binary a, Typeable a) => String -> MVar a -> Process (ExtVar a)
newExtVar name var = do
  pid <- spawnLocal $ extVarServer name var
  let eVar = MkExtVar (processNodeId pid) name
  Log.info "Made ExtVar" eVar
  pure eVar

-- | Kill the server underlying the 'ExtVar'. Subsequent calls from
-- clients may block indefinitely.
killExtVar :: forall a . (Binary a, Typeable a) => ExtVar a -> Process ()
killExtVar (MkExtVar nid name) = nsendRemote nid name $ Shutdown @a

withSelf
  :: (Binary b, Typeable b, Binary a, Typeable a)
  => ExtVar a
  -> (SendPort b -> ExtVarMessage a)
  -> Process b
withSelf (MkExtVar nid name) mkMessage = do
  (sendSelf, recvSelf) <- newChan
  nsendRemote nid name (mkMessage sendSelf)
  receiveChan recvSelf

-- | 'takeExtVar', etc. are analogous to 'takeMVar', etc. All
-- functions block until they receive a response from the host.

takeExtVar :: (Binary a, Typeable a) => ExtVar a -> Process a
takeExtVar eVar = withSelf eVar Take

tryTakeExtVar :: (Binary a, Typeable a) => ExtVar a -> Process (Maybe a)
tryTakeExtVar eVar = withSelf eVar TryTake

putExtVar :: (Binary a, Typeable a) => ExtVar a -> a -> Process ()
putExtVar eVar a = withSelf eVar $ Put a

tryPutExtVar :: (Binary a, Typeable a) => ExtVar a -> a -> Process Bool
tryPutExtVar eVar a = withSelf eVar $ TryPut a

readExtVar :: (Binary a, Typeable a) => ExtVar a -> Process a
readExtVar eVar = withSelf eVar Read

tryReadExtVar :: (Binary a, Typeable a) => ExtVar a -> Process (Maybe a)
tryReadExtVar eVar = withSelf eVar TryRead

withExtVar :: (Binary a, Typeable a) => ExtVar a -> (a -> Process b) -> Process b
withExtVar eVar = bracket (takeExtVar eVar) (putExtVar eVar)

modifyExtVar_ :: (Binary a, Typeable a) => ExtVar a -> (a -> Process a) -> Process ()
modifyExtVar_ eVar go = mask $ \restore -> do
  a  <- takeExtVar eVar
  a' <- restore (go a) `onException` putExtVar eVar a
  putExtVar eVar a'

modifyExtVar :: (Binary a, Typeable a) => ExtVar a -> (a -> Process (a,b)) -> Process b
modifyExtVar eVar go = mask $ \restore -> do
  a      <- takeExtVar eVar
  (a',b) <- restore (go a) `onException` putExtVar eVar a
  putExtVar eVar a'
  pure b

-- | 'IO' versions of 'ExtVar' functions, for convenience.

takeExtVarIO :: (Binary a, Typeable a) => ExtVar a -> IO a
takeExtVarIO = runProcessLocal . takeExtVar

tryTakeExtVarIO :: (Binary a, Typeable a) => ExtVar a -> IO (Maybe a)
tryTakeExtVarIO = runProcessLocal . tryTakeExtVar

putExtVarIO :: (Binary a, Typeable a) => ExtVar a -> a -> IO ()
putExtVarIO eVar = runProcessLocal . putExtVar eVar

tryPutExtVarIO :: (Binary a, Typeable a) => ExtVar a -> a -> IO Bool
tryPutExtVarIO eVar = runProcessLocal . tryPutExtVar eVar

readExtVarIO :: (Binary a, Typeable a) => ExtVar a -> IO a
readExtVarIO = runProcessLocal . readExtVar

tryReadExtVarIO :: (Binary a, Typeable a) => ExtVar a -> IO (Maybe a)
tryReadExtVarIO = runProcessLocal . tryReadExtVar

withExtVarIO :: (Binary a, Typeable a) => ExtVar a -> (a -> IO b) -> IO b
withExtVarIO eVar go = runProcessLocal $ withExtVar eVar (liftIO . go)

modifyExtVarIO_ :: (Binary a, Typeable a) => ExtVar a -> (a -> IO a) -> IO ()
modifyExtVarIO_ eVar go = runProcessLocal $ modifyExtVar_ eVar (liftIO . go)

modifyExtVarIO :: (Binary a, Typeable a) => ExtVar a -> (a -> IO (a,b)) -> IO b
modifyExtVarIO eVar go = runProcessLocal $ modifyExtVar eVar (liftIO . go)
