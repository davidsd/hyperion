{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveAnyClass #-}

module Hyperion.ObjectId where

import           Data.BinaryHash             (hashBase64Safe)
import Control.Monad.IO.Class (MonadIO)
import Control.Monad.Catch (MonadCatch)
import Control.Monad.Reader (MonadReader)
import Data.Typeable (Typeable)
import qualified Data.Text as Text
import qualified Hyperion.Database as DB
import Data.Binary (Binary)
import GHC.Generics (Generic)
import Data.Aeson (FromJSON, ToJSON)

-- | An identifier for an object, useful for building filenames and
-- database entries.
newtype ObjectId = ObjectId String
  deriving (Eq, Ord, Generic, Binary, FromJSON, ToJSON)

-- | Convert an ObjectId to a String. With the current implementation
-- of 'getObjectId', this string will contain only digits.
objectIdToString :: ObjectId -> String
objectIdToString (ObjectId i) = "Object_" ++ i

-- | Convert an ObjectId to Text. With the current implementation
-- of 'getObjectId', this string will contain only digits.
objectIdToText :: ObjectId -> Text.Text
objectIdToText = Text.pack . objectIdToString

-- | The ObjectId of an object is the absolute value of its hash. The
-- first time it is called on a given object, 'getObjectId' comptues
-- the ObjectId and stores it in the database before returning
-- it. Subsequent calls read the value from the database.
getObjectId
  :: ( Binary a
     , Typeable a
     , ToJSON a
     , DB.HasDB env
     , MonadReader env m
     , MonadIO m
     , MonadCatch m
     )
  => a -> m ObjectId
getObjectId = DB.memoizeWithMap
  (DB.KeyValMap "objectIds")
  (pure . ObjectId . hashBase64Safe)
