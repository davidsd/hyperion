{-# LANGUAGE DeriveAnyClass      #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE FlexibleContexts       #-}
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
-- > [Thu 01/06/22 13:04:17] New ExtVar: extVar @Int "login1.cm.cluster:39443:0" "test"
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
  , newEmptyExtVar
  , makeExtVar
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
  , newExtVarStream
  ) where

import Control.Monad.IO.Class (MonadIO)
import Control.Monad.Base (MonadBase, liftBase)
import           Control.Concurrent.MVar     (MVar, newEmptyMVar, newMVar, modifyMVar,
                                              putMVar, readMVar, takeMVar,
                                              tryPutMVar, tryReadMVar,
                                              tryTakeMVar)
import           Control.Distributed.Process (NodeId (..), Process, SendPort,
                                              expect, getSelfPid, liftIO,
                                              newChan, nsendRemote,
                                              processNodeId, receiveChan,
                                              register, sendChan, spawnLocal)
import           Control.Monad               (void)
import           Control.Monad.Catch         (bracket, mask, onException)
import           Data.Binary                 (Binary, decodeOrFail, encode)
import           Data.ByteString             (ByteString)
import           Data.IORef                  (IORef, atomicModifyIORef',
                                              newIORef)
import           Data.Text                   (Text, pack)
import           GHC.Generics                (Generic)
import qualified Hyperion.Log                as Log
import           Hyperion.Remote             (runProcessLocal)
import           Network.Transport           (EndPointAddress (..))
import           System.IO.Unsafe            (unsafePerformIO)
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
-- entry in the log of the host machine.
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

-- [Note: expect] Due to a bug (?) in GHC/GHCi, when a datatype is
-- defined in a library that is loaded in GHCi, then the TypeRep
-- Fingerprint assigned to it is different in GHCi and a compiled
-- Haskell program. This causes 'expect' not to work correctly because
-- it cannot match Fingerprints of incoming messages. Instead, we
-- 'expect' a 'ByteString' and decode it by hand, discarding cases
-- where decoding fails.
--
extVarServer :: forall a . (Typeable a, Binary a) => String -> MVar a -> Process ()
extVarServer name var = do
  pid <- getSelfPid
  register name pid
  let
    -- Reconstruct the ExtVar for logging purposes
    eVar = MkExtVar @a (processNodeId pid) name

    forClient :: (Typeable b, Binary b) => Text -> SendPort b -> IO b -> Process ()
    forClient cmd client run = do
      Log.text $ cmd <> " (" <> pack (show eVar) <> ")"
      void $ spawnLocal $ liftIO run >>= sendChan client
      go

    go = do
      -- We read the message encoded as a ByteString. See [Note:
      -- expect] for an explanation.
      encodedMsg <- expect
      case decodeOrFail encodedMsg of
        Right (_, _, cmd) -> case cmd of
          Take c            -> forClient "takeExtVar"    c $ takeMVar var
          TryTake c         -> forClient "tryTakeExtVar" c $ tryTakeMVar var
          Put contents c    -> forClient "putExtVar"     c $ putMVar var contents
          TryPut contents c -> forClient "tryPutExtVar"  c $ tryPutMVar var contents
          Read c            -> forClient "readExtVar"    c $ readMVar var
          TryRead c         -> forClient "tryReadExtVar" c $ tryReadMVar var
          Shutdown            -> pure ()
        Left (_, _, e) -> Log.warn "Couldn't decode ExtVar message" e
  go


extVarCounter :: IORef Integer
extVarCounter = unsafePerformIO (newIORef 0)
{-# NOINLINE extVarCounter #-}

newExtVarName :: IO String
newExtVarName = fmap (("extVar:" <>) . show) $ atomicModifyIORef' extVarCounter $ \c -> (c+1,c)

-- | Make a new 'ExtVar' containing 'x'. Return both the 'ExtVar' and
-- its underlying 'MVar'.
newExtVar :: (Binary a, Typeable a) => a -> Process (MVar a, ExtVar a)
newExtVar x = do
  m <- liftIO $ newMVar x
  e <- makeExtVar m
  pure (m, e)

-- | Make a new empty 'ExtVar'. Return both the 'ExtVar' and its
-- underlying 'MVar'.
newEmptyExtVar :: (Binary a, Typeable a) => Process (MVar a, ExtVar a)
newEmptyExtVar = do
  m <- liftIO $ newEmptyMVar
  e <- makeExtVar m
  pure (m, e)

-- | Make a new 'ExtVar' from an 'MVar'. The host program can continue
-- to use the 'MVar' as usual.
makeExtVar :: (Binary a, Typeable a) => MVar a -> Process (ExtVar a)
makeExtVar m = do
  name <- liftIO $ newExtVarName
  pid <- spawnLocal $ extVarServer name m
  let e = MkExtVar (processNodeId pid) name
  Log.text $ "New ExtVar: " <> pack (show e)
  pure e

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
  nsendRemote nid name (encode (mkMessage sendSelf))
  receiveChan recvSelf

-- | 'takeExtVar', etc. are analogous to 'takeMVar', etc. All
-- functions block until they receive a response from the host.
--
-- [Note: Safety] The functions 'takeExtVar', 'tryTakeExtVar', and
-- those that use them like 'withExtVar', 'modifyExtVar_', and
-- 'modifyExtVar' (and all of their IO variants) must be used with
-- care. On the host side, they cause data to be taken out of the
-- underlying 'MVar'. If an exception occurs, that data will not be
-- automatically replaced. Thus, the underlying 'MVar' could remain
-- empty and the data that was in it may be lost.
--
-- Here is an example situation where that would occur. Suppose that
-- we have an 'ExtVar' with type 'String':
--
-- > extVar @String "host.address.com" "extVar:0"
--
-- However, suppose that a client tries to take an 'ExtVar' with the
-- same address and name, but the wrong type:
--
-- >>> takeExtVarIO $ extVar @Int "host.address.com" "extVar:0"
--
-- On the host, the 'String' will be removed from the 'MVar',
-- serialized to 'ByteString', and sent to the client. (The 'host' no
-- longer has the data.) The client will try to deserialize the
-- 'ByteString' to an 'Int', which will fail (because 'Int' is the
-- incorrect type) and throw an exception. As 'takeExtVar' is
-- currently implemented, the data will never get sent back to the
-- host.
--
-- It is the client's responsibility to make sure this doesn't
-- happen. In a GHCi session, it is recommended that you use
-- 'readExtVarIO' first to make sure your connection is good and you
-- have the right 'ExtVar' *including its type*, before you use
-- functions like 'takeExtVar'.
--
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

-- | Store the given list in an 'ExtVar' and return an action that
-- repeatedly pops the first element from the list until there are
-- none left. An external client can freely modify the contents of the
-- 'ExtVar', and in this way insert or delete elements by hand while
-- the program is running.
newExtVarStream
  :: (Binary a, Typeable a, MonadIO m, MonadBase Process n)
  => [a]
  -> n (ExtVar [a], m (Maybe a))
newExtVarStream vs = liftBase $ do
  (mVar, eVar) <- newExtVar vs
  let pop = 
        liftIO $ modifyMVar mVar $ pure . \case
        []     -> ([], Nothing)
        u : us -> (us, Just u)
  pure (eVar, pop)
