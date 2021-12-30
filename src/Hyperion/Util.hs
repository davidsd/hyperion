{-# LANGUAGE ConstraintKinds   #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PolyKinds         #-}
{-# LANGUAGE RankNTypes        #-}
{-# LANGUAGE TypeOperators     #-}

module Hyperion.Util where

import           Control.Concurrent
import           Control.Monad
import           Control.Monad.Except
import           Data.BinaryHash       (hashBase64Safe)
import qualified Data.ByteString.Char8 as B
import           Data.Constraint       (Constraint, Dict (..))
import           Data.IORef            (IORef, atomicModifyIORef', newIORef)
import           Data.Text             (Text)
import qualified Data.Text             as Text
import qualified Data.Text.Lazy        as LazyText
import           Data.Time.Clock       (NominalDiffTime)
import qualified Data.Vector           as V
import qualified Hyperion.Log          as Log
import           Network.Mail.Mime     (Address (..), renderSendMail,
                                        simpleMail')
import           Numeric               (showIntAtBase)
import           System.Directory
import           System.FilePath.Posix (replaceDirectory)
import           System.IO.Unsafe      (unsafePerformIO)
import           System.Posix.Files    (readSymbolicLink)
import           System.Random         (randomRIO)
import qualified Text.ShellEscape      as Esc

-- | An opaque type representing a unique object. Only guaranteed to
-- be unique in one instance of a running program. For example, if we
-- allowed Unique's to be serialized and sent across the wire, or
-- stored and retrieved from a database, they would no longer be
-- guaranteed to be unique.
newtype Unique = MkUnique Integer
  deriving (Eq, Ord)

-- | A Unique can be rendered to a unique string of the characters
-- [0-9a-zA-Z]. This is used in Hyperion.Remote to generate new
-- ServiceId's.
instance Show Unique where
  show (MkUnique c) = showIntAtBase (fromIntegral (V.length chars)) ((chars V.!) . fromIntegral) c ""
    where
      chars = V.fromList $ ['0'..'9'] ++ ['a'..'z'] ++ ['A'..'Z']

uniqueSource :: IORef Integer
uniqueSource = unsafePerformIO (newIORef 0)
{-# NOINLINE uniqueSource #-}

-- | Get a new Unique.
newUnique :: IO Unique
newUnique = fmap MkUnique $ atomicModifyIORef' uniqueSource $ \c -> (c+1,c)

-- | 'IO' action that returns a random string of given length
randomString :: Int -> IO String
randomString len = replicateM len $ toAlpha <$> randomRIO (0, 51)
  where toAlpha n | n < 26    = toEnum (n + fromEnum 'A')
                  | otherwise = toEnum (n - 26 + fromEnum 'a')

-- | @retryRepeated n doTry m@ tries to run @doTry m@ n-1 times, after
-- which it runs @m@ 1 time. After each failure waits 15-90 seconds
-- randomly. Returns on first success.  Failure is represented by a
-- 'Left' value.
retryRepeated
  :: (Show e, MonadIO m)
  => Int -- ^ If this is 0 (or less), then it attempt @doTry m@ indefinitely.
  -> (m a -> m (Either e a))
  -> m a
  -> m a
retryRepeated n doTry m = go n
  where
    go 1 = m
    go k = doTry m >>= \case
      Left e  -> wait e >> go (k-1)
      Right b -> return b
    wait e = do
      t <- liftIO $ randomRIO (15, 90)
      Log.warn "Unsuccessful" (WaitRetry e t)
      liftIO $ threadDelay $ t*1000*1000

data WaitRetry e = WaitRetry
  { err      :: e
  , waitTime :: Int
  } deriving Show

-- | @retryExponential doTry m@ tries to run @doTry m@. After the n-th
-- successive failure, it waits time 2^n*t0, where t0 is a randomly
-- chosen time between 10 and 20 seconds. Unlike 'retryRepeated',
-- 'retryExponential' never eventually throws an exception, so it
-- should only be used when the only way to recover from the exception
-- without the whole program crashing is to retry until things
-- work. Typically this means it should only be used in the master
-- process.
retryExponential
  :: MonadIO m
  => (m a -> m (Either e a))
  -> (WaitRetry e -> m ())
  -> m a
  -> m a
retryExponential doTry handleErr m = go 1
  where
    go timeMultiplier = doTry m >>= \case
      Left e  -> wait timeMultiplier e >> go (2*timeMultiplier)
      Right b -> return b
    wait timeMultiplier e = do
      t <- liftIO . fmap (* timeMultiplier) $ randomRIO (10, 20)
      handleErr (WaitRetry e t)
      liftIO $ threadDelay $ t*1000*1000

-- | Send an email to 'toAddr' with the given 'subject' and 'body'.
emailMessage
  :: MonadIO m
  => Text
  -> Text
  -> Text
  -> m ()
emailMessage toAddr subject body = liftIO $ renderSendMail mail
  where
    mail      = simpleMail' toAddr' fromAddr' subject (LazyText.fromStrict body)
    toAddr'   = Address Nothing toAddr
    fromAddr' = Address (Just "Hyperion") toAddr

-- | Send an email to 'toAddr' showing the object 'a'. The subject
-- line is "msg: ...", where 'msg' is the first argument and "..." is
-- the first 40 characters of 'show a'.
email :: (Show a, MonadIO m) => Text -> Text -> a -> m ()
email msg toAddr a = emailMessage toAddr subject body
  where
    subject = "[Hyperion] " <> msg <> ": " <> Text.take 40 (Text.pack (show a))
    body = Log.prettyShowText a

-- | Send an email with msg "Error"
emailError :: (Show a, MonadIO m) => Text -> a -> m ()
emailError = email "Error"

-- | Takes a path and a list of 'String' arguments, shell-escapes the arguments,
-- and combines everything into a single string.
shellEsc :: FilePath -> [String] -> String
shellEsc cmd args = unwords $ cmd : map (B.unpack . Esc.bytes . Esc.sh . B.pack) args

----------------- Time ----------------------

minute :: NominalDiffTime
minute = 60

hour :: NominalDiffTime
hour = 60*minute

day :: NominalDiffTime
day = 24*hour

nominalDiffTimeToMicroseconds :: NominalDiffTime -> Int
nominalDiffTimeToMicroseconds t = ceiling (t*1000*1000)

----------------- Filesystem ----------------------

myExecutable :: IO FilePath
myExecutable = readSymbolicLink "/proc/self/exe"

-- | Determine the path to this executable and save a copy to the specified dir
-- with a string appended to filename.
savedExecutable
  :: FilePath
  -> String -- ^ the string to append
  -> IO FilePath
savedExecutable dir idString = do
  selfExec <- myExecutable
  createDirectoryIfMissing True dir
  let savedExec = replaceDirectory (selfExec ++ "-" ++ idString) dir
  copyFile selfExec savedExec
  return savedExec

-- | Replaces all non-allowed characters by @\'_\'@. Allowed characters are alphanumerics and .,-,_
sanitizeFileString :: String -> FilePath
sanitizeFileString = map (\c -> if c `notElem` allowed then '_' else c)
  where
    allowed = ['a'..'z'] ++ ['A'..'Z'] ++ ['0'..'9'] ++ ".-_"

-- | Truncates a string to a string of at most given length, replacing dropped
-- characters by a hash. The hash takes up 43 symbols,
-- so asking for a smaller length will still return 43 symbols.
hashTruncateString :: Int -> String -> String
hashTruncateString len s | length s <= len = s
hashTruncateString len s =
  take numTake s ++ (if numTake > 0 then "-" else "") ++ hString
  where
    numTake = len - 44
    hString  = hashBase64Safe (drop numTake s)

-- | Synonim for @'hashTruncateString' 230@
hashTruncateFileName :: String -> String
hashTruncateFileName = hashTruncateString 230

-- | Turn an expression with a constraint into a function of an
-- explicit dictionary
withDict :: forall (c :: Constraint) r . (c => r) -> Dict c -> r
withDict r Dict = r

