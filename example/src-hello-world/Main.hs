{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StaticPointers    #-}

module Main where

import           Control.Applicative (many)
import qualified Data.Text           as Text
import           Hyperion
import qualified Hyperion.Log        as Log
import qualified Options.Applicative as Opts

data HelloOptions = HelloOptions
  { names   :: [String]
  , workDir :: FilePath
  } deriving (Show)

getGreeting :: String -> IO String
getGreeting name = do
  Log.info "Generating greeting for" name
  return $ "Hello " ++ name ++ "!"

-- | Run a Slurm job to compute a greeting
remoteGetGreeting :: String -> Cluster String
remoteGetGreeting = remoteEval (static (remoteFnIO getGreeting))

-- | Compute greetings concurrently in separate Slurm jobs and print them
printGreetings :: HelloOptions -> Cluster ()
printGreetings options = do
  greetings <- mapConcurrently remoteGetGreeting (names options)
  mapM_ (Log.text . Text.pack) greetings

-- | Command-line options parser
helloOpts :: Opts.Parser HelloOptions
helloOpts = HelloOptions
  <$> many (Opts.option Opts.str (Opts.long "name"))
  <*> Opts.option Opts.str (Opts.long "workDir")

main :: IO ()
main = hyperionMain helloOpts (defaultHyperionConfig . workDir) printGreetings
