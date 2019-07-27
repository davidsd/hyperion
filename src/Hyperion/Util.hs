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

randomString :: Int -> IO String
randomString len = replicateM len $ toAlpha <$> randomRIO (0, 51)
  where toAlpha n | n < 26    = toEnum (n + fromEnum 'A')
                  | otherwise = toEnum (n - 26 + fromEnum 'a')

retryRepeated :: (Show e, MonadIO m) => Int -> (m a -> m (Either e a)) -> m a -> m a
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

-- Determine the path to this executable and save a copy with idString appended
savedExecutable :: FilePath -> String -> IO FilePath
savedExecutable dir idString = do
  selfExec <- myExecutable
  createDirectoryIfMissing True dir
  let savedExec = replaceDirectory (selfExec ++ "-" ++ idString) dir
  copyFile selfExec savedExec
  return savedExec

sanitizeFileString :: String -> FilePath
sanitizeFileString = map (\c -> if c `notElem` allowed then '_' else c)
  where
    allowed = ['a'..'z'] ++ ['A'..'Z'] ++ ['0'..'9'] ++ ".-_"

hashTruncateString :: Int -> String -> String
hashTruncateString len s | length s <= len = s
hashTruncateString len s =
  take numTake s ++ (if numTake > 0 then "-" else "") ++ hString
  where
    numTake = len - 12
    chars   = ['a'..'z'] ++ ['A'..'Z'] ++ ['0'..'9']
    h       = abs (hashWithSalt 0 (drop numTake s))
    hString = map (chars !!) (digits (length chars) h)

hashTruncateFileName :: String -> String
hashTruncateFileName = hashTruncateString 230
