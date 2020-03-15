{-# LANGUAGE OverloadedStrings #-}

module Hyperion.Log where

import           Control.Monad.Catch       (Exception, MonadThrow, throwM)
import           Control.Monad.IO.Class    (MonadIO, liftIO)
import           Data.Monoid               ((<>))
import           Data.Text                 (Text)
import qualified Data.Text                 as T
import           Data.Time.Format          (defaultTimeLocale, formatTime)
import           Data.Time.LocalTime       (getZonedTime)
import           GHC.IO.Handle             (hDuplicateTo)
import           System.Console.Concurrent (errorConcurrent)
import           System.Directory          (createDirectoryIfMissing)
import           System.FilePath.Posix     (takeDirectory)
import           System.IO                 (IOMode (..), hFlush, openFile,
                                            stderr, stdout)
import           Text.PrettyPrint          ((<+>))
import qualified Text.PrettyPrint          as PP (render, text)
import           Text.Show.Pretty          (ppDoc)

prettyShowText :: Show a => a -> Text
prettyShowText a = T.pack (PP.render (ppDoc a))

text :: MonadIO m => Text -> m ()
text msg = liftIO $ do
  now <- T.pack . formatTime defaultTimeLocale "[%a %D %X] " <$> getZonedTime
  errorConcurrent (now <> msg <> "\n")

info :: (Show a, MonadIO m) => Text -> a -> m ()
info msg a = text $ T.pack $ PP.render $ PP.text (T.unpack msg ++ ":") <+> ppDoc a

warn :: (Show a, MonadIO m) => Text -> a -> m ()
warn msg a = info ("WARN: " <> msg) a

err :: (Show a, MonadIO m) => a -> m ()
err e = info "ERROR" e

throw :: (MonadThrow m, MonadIO m, Exception e) => e -> m a
throw e = do
  err e
  throwM e

throwError :: MonadIO m => String -> m a
throwError e = do
  text $ "ERROR: " <> T.pack e
  error e

flush :: IO ()
flush = hFlush stderr

redirectToFile :: FilePath -> IO ()
redirectToFile logFile = do
  createDirectoryIfMissing True (takeDirectory logFile)
  h <- openFile logFile WriteMode
  hDuplicateTo h stdout
  hDuplicateTo h stderr
