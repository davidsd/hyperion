{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StaticPointers    #-}
{-# LANGUAGE MultiWayIf #-}

module Main where

import           Control.Applicative (many)
import qualified Data.Text           as Text
import           Hyperion
import qualified Hyperion.Log        as Log
import qualified Options.Applicative as Opts
import Control.Distributed.Process (Process, liftIO, getSelfPid, kill)
import qualified Hyperion.LockMap as LM
import Control.Concurrent (threadDelay)
import Control.Monad.Trans (lift)
import Control.Monad.Reader (local)

data HelloOptions = HelloOptions
  { names   :: [String]
  , workDir :: FilePath
  } deriving (Show)

object :: (Int, String)
object = (5, "Hello")

getGreeting :: String -> Process String
getGreeting name = do
  getMasterNodeId >>= Log.info "My remote context is "
  Log.info "Generating greeting for" name
  LM.withLock object $ \_ -> do
    Log.info "Locked " object
    liftIO Log.flush
    if | name == "fail" -> do
           liftIO $ threadDelay $ 3*1000*1000
           fail "Planned failure"
       | name == "kill" -> do
           liftIO $ threadDelay $ 3*1000*1000
           pid <- getSelfPid
           kill pid "Planned suicide"
       | otherwise -> liftIO . threadDelay $ 60*1000*1000
  Log.info "Unlocked " object
  return $ "Hello " ++ name ++ "!"

getGreetings :: [String] -> Job [String]
getGreetings names = local (setTaskCpus 1) $ do
  mapConcurrently remoteGetGreeting names

-- | Run a Slurm job to compute a greeting
remoteGetGreeting :: String -> Job String
remoteGetGreeting = remoteEval (static (remoteFn getGreeting))

-- | Run a Slurm job to compute a greeting
remoteGetGreetings :: [String] -> Cluster [String]
remoteGetGreetings = remoteEvalJob (static (remoteFnJob getGreetings))

-- | Compute greetings concurrently in separate Slurm jobs and print them
printGreetings :: HelloOptions -> Cluster ()
printGreetings options = local (setJobType (MPIJob 2 1)) $ do
  lift getMasterNodeId >>= Log.info "My remote context is "
  greetings <- remoteGetGreetings (names options)
  key <- lift $ LM.lockRemote object
  Log.info "Locked " object
  liftIO $ threadDelay $ 10*1000*1000
  lift $ LM.unlockRemote key
  Log.info "Unlocked " object
  mapM_ (Log.text . Text.pack) greetings

-- | Command-line options parser
helloOpts :: Opts.Parser HelloOptions
helloOpts = HelloOptions
  <$> many (Opts.option Opts.str (Opts.long "name"))
  <*> Opts.option Opts.str (Opts.long "workDir")

main :: IO ()
main = hyperionMain helloOpts (defaultHyperionConfig . workDir) printGreetings
