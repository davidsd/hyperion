{-# LANGUAGE DerivingStrategies  #-}
{-# LANGUAGE OverloadedRecordDot #-}

module Hyperion.ServiceId
  ( ServiceId(..)
  , serviceIdToString
  , serviceIdToText
  , withServiceId
  ) where

import Control.Distributed.Process (Process, getSelfPid, register, unregister)
import Control.Monad.Catch         (bracket)
import Control.Monad.IO.Class      (liftIO)
import Data.Aeson                  (FromJSON, ToJSON)
import Data.Binary                 (Binary)
import Data.Text                   (Text)
import Data.Text                   qualified as Text
import Hyperion.Util               (newUnique)
import Servant                     (FromHttpApiData (..), ToHttpApiData (..))

-- | A label for a worker, unique for the given process (but not
-- unique across the whole distributed program).
newtype ServiceId = ServiceId String
  deriving stock (Eq, Ord, Show)
  deriving newtype (Binary, ToJSON, FromJSON, FromHttpApiData, ToHttpApiData)

serviceIdToText :: ServiceId -> Text
serviceIdToText = Text.pack . serviceIdToString

serviceIdToString :: ServiceId -> String
serviceIdToString (ServiceId s) = s

-- | Registers ('register') the current process under a random
-- 'ServiceId', then passes the 'ServiceId' to the given continuation.
-- After the continuation returns, unregisters ('unregister') the
-- 'ServiceId'.
withServiceId :: (ServiceId -> Process a) -> Process a
withServiceId = bracket newServiceId (\(ServiceId s) -> unregister s)
  where
    newServiceId = do
      s <- liftIO $ show <$> newUnique
      getSelfPid >>= register s
      return (ServiceId s)
