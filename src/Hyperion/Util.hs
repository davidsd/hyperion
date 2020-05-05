{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators     #-}

module Hyperion.Util where

import           Control.Concurrent
import           Control.Monad
import           Control.Monad.Except
import qualified Data.ByteString.Char8 as B
import           Data.Digits           (digits)
import           Data.Hashable         (hashWithSalt)
import           Data.Time.Clock       (NominalDiffTime)
import qualified Hyperion.Log as Log
import           System.Directory
import           System.FilePath.Posix (replaceDirectory)
import           System.Posix.Files    (readSymbolicLink)
import           System.Random         (randomRIO)
import qualified Text.ShellEscape      as Esc

-- | 'IO' action that returns a random string of given length 
randomString :: Int -> IO String
randomString len = replicateM len $ toAlpha <$> randomRIO (0, 51)
  where toAlpha n | n < 26    = toEnum (n + fromEnum 'A')
                  | otherwise = toEnum (n - 26 + fromEnum 'a')

-- | @retryRepeated n doTry m@ tries to run @doTry m@ n-1 times, after which it 
-- runs @m@ 1 time. After each failure waits 15-90 seconds randomly. Returns on first success.
-- Failure is represented by a 'Left' value. 
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
      Left e -> wait e >> go (k-1)
      Right b -> return b
    wait e = do
      t <- liftIO $ randomRIO (15, 90)
      Log.warn "Unsuccessful" e
      Log.warn "Waiting for" t
      liftIO $ threadDelay $ t*1000*1000

-- | Takes a path and a list of 'String' arguments, shell-escapes the arguments,
-- and combines everything into a single string.
shellEsc :: FilePath -> [String] -> String
shellEsc cmd args = unwords $ cmd : map (B.unpack . Esc.bytes . Esc.sh . B.pack) args

-- | Given a function that takes a monadic action, allow us to inspect
-- the argument to that function. Only works if f is guaranteed to
-- evaluate its argument exactly once. This function is useful in
-- combination with remoteBind, since it allows one to inspect the
-- argument produced by the monadic action passed to the given
-- continuation.
onceWithArgument :: (MonadIO m, MonadIO n) => (m a -> n b) -> m a -> n (a, b)
onceWithArgument f ma = do
  argVar <- liftIO newEmptyMVar
  let ma' = do
        a <- ma
        couldPut <- liftIO (tryPutMVar argVar a)
        when (not couldPut) $
          -- TODO: should this be an exception?
          Log.warn "onceWithArgument: argument evaluated multiple times" ()
        return a
  b <- f ma'
  a <- liftIO $ readMVar argVar
  return (a, b)

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
-- characters by a hash. The hash takes up 11 symbols (depends on @'maxBound'::'Int'@),
-- so asking for a smaller length will not work.
hashTruncateString :: Int -> String -> String
hashTruncateString len s | length s <= len = s
hashTruncateString len s =
  take numTake s ++ (if numTake > 0 then "-" else "") ++ hString
  where
    numTake = len - 12
    chars   = ['a'..'z'] ++ ['A'..'Z'] ++ ['0'..'9']
    h       = abs (hashWithSalt 0 (drop numTake s))
    hString = map (chars !!) (digits (length chars) h)

-- | Synonim for @'hashTruncateString' 230@
hashTruncateFileName :: String -> String
hashTruncateFileName = hashTruncateString 230

-- *  Tuples 
-- $
-- These currying/uncurrying routines are useful because remote
-- functions can only take a single argument

-- | Converts an uncurried function to a curried function.
curry3 :: ((a, b, c) -> d) -> a -> b -> c -> d
curry3 f a b c = f (a,b,c)

-- | Converts a curried function to a function on a triple.
uncurry3 :: (a -> b -> c -> d) -> ((a, b, c) -> d)
uncurry3 f ~(a,b,c) = f a b c

-- | Converts an uncurried function to a curried function.
curry4 :: ((a, b, c, d) -> e) -> a -> b -> c -> d -> e
curry4 f a b c d = f (a,b,c,d)

-- | Converts a curried function to a function on a quadruple.
uncurry4 :: (a -> b -> c -> d -> e) -> ((a, b, c, d) -> e)
uncurry4 f ~(a,b,c,d) = f a b c d
