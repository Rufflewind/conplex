{-# LANGUAGE OverloadedStrings #-}
module Main where
import Control.Arrow ((>>>), first, left)
import Control.Applicative
import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Concurrent.Async
import Control.Concurrent.MVar
import Control.Exception
import Control.Monad
import Control.Monad.Error.Class
import Control.Monad.Trans.Maybe
import Control.Monad.IO.Class
import Data.ByteString.Char8 (ByteString)
import Data.Foldable
import Data.Function ((&))
import Data.IntCast
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Maybe (fromMaybe)
import Data.Monoid ((<>))
import Data.Sequence (Seq, ViewL((:<)), (|>))
import Data.Serialize
import Data.Tuple (swap)
import Data.Typeable (Typeable, typeRep)
import Data.Word (Word64, Word32)
import Foreign (Storable, sizeOf)
import Network.Simple.TCP
import System.IO
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as BL
import qualified Data.Map.Strict as Map
import qualified Data.Sequence as Seq
import Common
import Conplex

main :: IO ()
main = withSocketsDo $ do

  forkIO_ (serveTransporter (bindHost, bindPort)
                            ((,) proxy . (,) destHost <$> destPorts))
  -- forkIO (portForward (Host "127.0.0.1", show 9001) ("127.0.0.1", "9002"))
  for_ ((,) (Host destHost) <$> destPorts) $ \ (bindHost, bindPort) ->
    (serveReceptor (bindHost, bindPort) (Nothing, ("127.0.0.1", "8080")))

  standby
  where
    bindHost = Host "127.0.0.1"
    bindPort = 8000 :: Int
    destHost = "127.0.0.1"
    destPorts = [12000 .. 12001 :: Int]
    proxy = Nothing -- Just ("127.0.0.0", 7999)
