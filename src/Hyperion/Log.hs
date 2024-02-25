{-# LANGUAGE OverloadedStrings #-}

module Hyperion.Log where

import Control.Monad.Catch       (Exception, MonadThrow, throwM)
import Control.Monad.IO.Class    (MonadIO, liftIO)
import Data.IORef                (IORef, newIORef, readIORef, writeIORef)
import Data.Text                 (Text)
import Data.Text                 qualified as T
import Data.Time.Format          (defaultTimeLocale, formatTime)
import Data.Time.LocalTime       (getZonedTime)
import GHC.IO.Handle             (hDuplicateTo)
import System.Console.Concurrent (errorConcurrent)
import System.Directory          (createDirectoryIfMissing)
import System.FilePath.Posix     (takeDirectory)
import System.IO                 (IOMode (..), hFlush, openFile, stderr, stdout)
import System.IO.Unsafe          (unsafePerformIO)
import Text.PrettyPrint          qualified as PP (render, text)
import Text.PrettyPrint          ((<+>))
import Text.Show.Pretty          (ppDoc)

-- * General comments
-- $
-- This module contains some simple functions for logging and throwing errors.
-- The logging is done to 'stderr'.
-- The functions use 'errorConcurrent' to write to stderr (through 'text').
--
-- The output can be redirected from 'stderr' to a file by using 'redirectToFile'.

showText :: Show a => a -> Text
showText = T.pack . show

prettyShowText :: Show a => a -> Text
prettyShowText a = T.pack (PP.render (ppDoc a))

rawText :: MonadIO m => Text -> m ()
rawText t = liftIO $ errorConcurrent t

-- | Outputs the first argument to log. Prepends current time in the format
-- @[%a %D %X]@ where @%a@ is day of the week, @%D@ is date in @mm\/dd\/yy@ format, @%X@ is
-- current time of day in some default locale.
text :: MonadIO m => Text -> m ()
text msg = liftIO $ do
  now <- T.pack . formatTime defaultTimeLocale "[%a %D %X] " <$> getZonedTime
  errorConcurrent (now <> msg <> "\n")

-- | Outputs a string to log using 'text' where the string is a pretty version of the first
-- two arguments
info :: (Show a, MonadIO m) => Text -> a -> m ()
info msg a = text $ T.pack $ PP.render $ PP.text (T.unpack msg ++ ":") <+> ppDoc a

-- | Same as 'info' but prepended by "WARN: ".
warn :: (Show a, MonadIO m) => Text -> a -> m ()
warn msg a = info ("WARN: " <> msg) a

-- | Shorthand for @'info' \"ERROR\"@
err :: (Show a, MonadIO m) => a -> m ()
err e = info "ERROR" e

-- | Same as 'throwM' but first logs the error using 'err'
throw :: (MonadThrow m, MonadIO m, Exception e) => e -> m a
throw e = do
  err e
  throwM e

-- | Same as 'error' but first logs the error using 'text' by prepending "ERROR: " to the first argument.
throwError :: MonadIO m => String -> m a
throwError e = do
  text $ "ERROR: " <> T.pack e
  error e

flush :: IO ()
flush = hFlush stderr

currentLogFile :: IORef (Maybe FilePath)
{-# NOINLINE currentLogFile #-}
currentLogFile = unsafePerformIO (newIORef Nothing)

getLogFile :: MonadIO m => m (Maybe FilePath)
getLogFile = liftIO (readIORef currentLogFile)

-- | Redirects log output to file by rewrting 'stdout' and 'stderr' handles.
redirectToFile :: FilePath -> IO ()
redirectToFile logFile = do
  createDirectoryIfMissing True (takeDirectory logFile)
  -- Use AppendMode so that if the program is accidentally run twice
  -- with the same arguments, we don't overwrite previous log files.
  h <- openFile logFile AppendMode
  writeIORef currentLogFile (Just logFile)
  hDuplicateTo h stdout
  hDuplicateTo h stderr
