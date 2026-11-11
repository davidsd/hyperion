{-# LANGUAGE DerivingStrategies  #-}
{-# LANGUAGE OverloadedRecordDot #-}

module Hyperion.ServiceId
  ( ServiceId(..)
  , serviceIdToOsString
  , serviceIdToText
  , newServiceId
  ) where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Aeson             (FromJSON, ToJSON)
import Data.Binary            (Binary)
import Data.Text              (Text)
import Hyperion.OsString      (OsString, fromText, showOs, toText)
import Hyperion.Util          (newUnique)
import Servant                (FromHttpApiData (..), ToHttpApiData (..))

-- | A label for a worker, unique for the given process (but not
-- unique across the whole distributed program).
newtype ServiceId = ServiceId OsString
  deriving stock (Eq, Ord, Show)
  deriving newtype (Binary, ToJSON, FromJSON)

instance ToHttpApiData ServiceId where
  toUrlPiece = serviceIdToText
instance FromHttpApiData ServiceId where
  parseUrlPiece = fmap (ServiceId . fromText) . parseUrlPiece


serviceIdToText :: ServiceId -> Text
serviceIdToText = toText . serviceIdToOsString

serviceIdToOsString :: ServiceId -> OsString
serviceIdToOsString (ServiceId s) = s

newServiceId :: MonadIO m => m ServiceId
newServiceId = liftIO $ ServiceId . showOs <$> newUnique
