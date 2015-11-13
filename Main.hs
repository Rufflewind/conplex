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
import Data.String (fromString)
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
import qualified Options.Applicative as O
import qualified Text.Parsec as P
import Common
import Conplex

main :: IO ()
main = do
  (flags, actions) <- O.execParser opts
  withSocketsDo . foldr1 concurrently_ $ do
    actions <&> \ action -> do
      when (flagVerbose flags) $
        print action
      case action of
        -- Forward src dst -> portForward src dst
        -- Transporter src dst -> serveTransporter src dst
        -- Receptor src dsts -> serveReceptor src dsts
        _ -> pure ()

opts :: O.ParserInfo (Flags, [Action])
opts =
  O.info
    (O.helper <*> ((,) <$> optFlags <*> some optAction))
    (O.fullDesc <> O.progDesc desc)
  where
    desc = "Inverse multiplexer for TCP connections.  " <>
           "Note that HOST may a simple host name, or of the form " <>
           "[socks5://SOCKSHOST:SOCKSPORT/HOST] " <>
           "(in this case, the square brackets are literal).  " <>
           "If BINDADDRESS is omitted, it defaults to localhost.  " <>
           "If BINDADDRESS is present but empty, it binds to all interfaces."

data Flags =
  Flags
  { flagVerbose :: Bool
  } deriving (Eq, Ord, Read, Show)

optFlags :: O.Parser Flags
optFlags =
  Flags <$>
  O.switch
    (O.short 'v' <>
     O.long "verbose" <>
     O.help "Display diagnostic information.")

data Action
  = Transporter (HostPreference, ServiceName) [ProxiedHostService]
  | Receptor (HostPreference, ServiceName) ProxiedHostService
  | Forward (HostPreference, ServiceName) ProxiedHostService
  deriving (Eq, Ord, Read, Show)

optAction :: O.Parser Action
optAction =
  O.option (O.eitherReader (parseEntries >=> parseForwardSpec Forward))
    (O.short 'f' <>
     O.long "forward" <>
     O.metavar forwardSpecTemplate <>
     O.help "Forward BINDPORT on BINDADDRESS to PORT on HOST.")
  <|>
  O.option (O.eitherReader (parseEntries >=> parseForwardSpec Receptor))
    (O.short 'm' <>
     O.long "merge" <>
     O.metavar forwardSpecTemplate <>
     O.help ("Merge connections received at BINDPORT on BINDADDRESS " <>
             "and forward them to PORT on HOST."))
  <|>
  O.option (O.eitherReader (parseEntries >=> parseTransporterSpec Transporter))
    (O.short 's' <>
     O.long "split" <>
     O.metavar transporterSpecTemplate <>
     O.help ("Split connections received at BINDPORT on BINDADDRESS " <>
             "and send them to PORT1 on HOST1, PORT2 on HOST2, .... " <>
             "An omitted HOST will inherit from the previous entry."))

forwardSpecTemplate :: String
forwardSpecTemplate = "[BINDADDRESS:]BINDPORT:HOST:PORT"

transporterSpecTemplate :: String
transporterSpecTemplate = "[BINDADDRESS:]BINDPORT:HOST1:PORT1[,[HOST2:]PORT2...]"

parseForwardSpec
  :: ((HostPreference, ServiceName) -> ProxiedHostService -> a)
  -> [[String]]
  -> Either String a
parseForwardSpec f entries =
  case entries of
    [headEntry] ->
      uncurry f . (parseProxy <$>) <$>
        maybeToEither err (parseHeadEntry headEntry)
    _ ->
      Left err
  where

    err = "must be of the form " <> forwardSpecTemplate

parseTransporterSpec
  :: ((HostPreference, ServiceName) -> [ProxiedHostService] -> a)
  -> [[String]]
  -> Either String a
parseTransporterSpec f entries =
  case entries of
    (headEntry : tailEntries) -> do
      (bindServ, (dh0, dp0)) <- maybeToEither err (parseHeadEntry headEntry)
      f bindServ . (parseProxy <$>) <$>
        maybeToEither err (grabServs ([dh0, dp0] : tailEntries))
    _ -> Left err
  where

    err = "must be of the form " <> transporterSpecTemplate

    grabServs ([h, p] : [h', p'] : r) = ((h, p) :) <$> grabServs ([h', p'] : r)
    grabServs ([h, p] : [p'] : r) = ((h, p) :) <$> grabServs ([h, p'] : r)
    grabServs [[h, p]] = Just [(h, p)]
    grabServs _ = Nothing

parseHeadEntry
  :: [String]
  -> Maybe ((HostPreference, ServiceName), HostService)
parseHeadEntry entry =
  case entry of
    [bp, dh, dp] -> Just ((Host "localhost", bp), (dh, dp))
    ["", bp, dh, dp] -> Just ((HostAny, bp), (dh, dp))
    [bh, bp, dh, dp] -> Just ((fromString bh, bp), (dh, dp))
    _ -> Nothing

parseEntries :: String -> Either String [[String]]
parseEntries input = left show (P.parse entries "" input)
  where

    entries = P.sepBy (P.sepBy entry (P.char ':')) (P.char ',') <* P.eof

    entry = bracketed <|> unbracketed

    unbracketed = many (P.satisfy (not . (`elem` ":,")))

    bracketed =
      (\ x y z -> [x] <> y <> [z]) <$>
        P.char '[' <*>
        many (P.satisfy (/= ']')) <*>
        P.char ']'

parseProxy :: HostService -> ProxiedHostService
parseProxy (h, p) = fromMaybe (Nothing, (h, p)) $ do
  (shp, h') <- eitherToMaybe (P.parse proxySpec "" h)
  entries <- eitherToMaybe (parseEntries shp)
  case entries of
    [[sh, sp]] -> Just (Just (sh, sp), (h', p))
    _ -> Nothing
  where

    proxySpec =
      (,) <$>
        (P.string "[socks5://" *>
         many (P.satisfy (/= '/')) <* P.char '/') <*>
        (many (P.satisfy (/= ']')) <* P.char ']')
