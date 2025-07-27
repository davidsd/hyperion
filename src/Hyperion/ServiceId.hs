{-# LANGUAGE DerivingStrategies  #-}
{-# LANGUAGE OverloadedRecordDot #-}

module Hyperion.ServiceId
  ( ServiceId(..)
  , serviceIdToString
  , serviceIdToText
  , newServiceId
  ) where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Aeson             (FromJSON, ToJSON)
import Data.Binary            (Binary)
import Data.Text              (Text)
import Data.Text              qualified as Text
import Hyperion.Util          (newUnique)
import Servant                (FromHttpApiData (..), ToHttpApiData (..))

-- | A label for a worker, unique for the given process (but not
-- unique across the whole distributed program).
newtype ServiceId = ServiceId String
  deriving stock (Eq, Ord, Show)
  deriving newtype (Binary, ToJSON, FromJSON, FromHttpApiData, ToHttpApiData)

serviceIdToText :: ServiceId -> Text
serviceIdToText = Text.pack . serviceIdToString

serviceIdToString :: ServiceId -> String
serviceIdToString (ServiceId s) = s

newServiceId :: MonadIO m => m ServiceId
newServiceId = liftIO $ ServiceId . show <$> newUnique
