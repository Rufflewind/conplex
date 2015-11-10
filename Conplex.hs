{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeSynonymInstances #-}
module Conplex where
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
import System.Entropy (getEntropy)
import System.Random.Shuffle (shuffleM)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as BL
import qualified Data.Map.Strict as Map
import qualified Data.Sequence as Seq
import Common

#define DERIVE_FROM_SERIALIZE_ENUM(Type) \
  instance Serialize (Type) where { \
    get = serializeEnumGet; \
    put = serializeEnumPut; \
  }; \
  instance SizedSerialize (Type) where \
    serializedSize = serializeEnumSize

maxChunkSize :: Int
maxChunkSize = 16 * 1024

maxBufferSize :: Int
maxBufferSize = 4 * 1024 * 1024

-- | Maximum number of concurrent connections.
maxConnections :: Int
maxConnections = 8 * 1024

chunkOverhead :: Int
chunkOverhead = 1024

portForward :: HostPreference
            -> ServiceName
            -> HostName
            -> ServiceName
            -> IO ()
portForward bindHost bindPort destHost destPort =
  serve   bindHost bindPort $ \ (s,  _) ->
  connect destHost destPort $ \ (s', _) ->
    forward s s'
    `concurrently_`
    forward s' s
  where forward s s' = do
          mx <- recv s maxChunkSize
          case mx of
            Nothing -> pure ()
            Just x  -> do
              send s' x
              forward s s'

keySize :: Int
keySize = 8 -- bytes

-- | Occurs if 'recv' fails.
data ConnectionClosedException =
  ConnectionClosedException
  deriving (Show, Typeable)
instance Exception ConnectionClosedException

-- | Occurs if 'generateConnectionID' fails.
data TooManyConnectionsException =
  TooManyConnectionsException
  deriving (Show, Typeable)
instance Exception TooManyConnectionsException

-- | Occurs if 'decode' fails.
data DecodeException =
  DecodeException
    String     -- What we tried to decode into
    ByteString -- Input that failed to decode
  deriving (Show, Typeable)
instance Exception DecodeException

sendChunk :: Socket -> (Pos, ByteString) -> IO ()
sendChunk s (pos, m) = sendMany s [encode pos, encode (sizeX (B.length m)), m]

-- | Can throw 'ConnectionClosedException'.
recvX :: Socket -> Int -> IO ByteString
recvX socket len =
  fromJustIO ConnectionClosedException =<<
  recv socket len

-- | Can throw 'ConnectionClosedException'.
recvExactX :: Socket -> Int -> IO ByteString
recvExactX socket len =
  fromJustIO ConnectionClosedException =<<
  recvExact socket len

recvExact :: Socket -> Int -> IO (Maybe ByteString)
recvExact socket len = runMaybeT (recvExactT socket len)

recvExactT :: Socket -> Int -> MaybeT IO ByteString
recvExactT socket len = BL.toStrict <$> recvExactLT socket len

recvExactLT :: Socket -> Int -> MaybeT IO BL.ByteString
recvExactLT socket 0   = pure mempty
recvExactLT socket len = do
  b <- MaybeT (recv socket len)
  (BL.fromStrict b <>) <$> recvExactLT socket (len - B.length b)

recvExpectX :: Socket -> ByteString -> IO ()
recvExpectX socket str = do
  str' <- recvExactX socket (B.length str)
  when (str /= str') $
    throwIO (DecodeException ("<recvExpectX:" <> show str <> ">") str')

-- | Can throw 'ConnectionClosedException' or the given exception.
recvThenDecodeX :: (SizedSerialize a, Typeable a) => Socket -> IO a
recvThenDecodeX socket =
  case [] of
    proxy ->
      (recvExactX socket (serializedSize proxy) >>=
       fromJustIO1 (exception proxy) (eitherToMaybe . decode)) <&>
      (`asTypeOfProxy` proxy)
  where exception proxy = DecodeException (show (typeRep proxy))

-- | Can throw 'ConnectionClosedException' or 'DecodeException'.
recvChunkX :: Socket -> IO (Pos, ByteString)
recvChunkX socket = do
  pos  <- recvThenDecodeX socket
  size <- recvThenDecodeX socket
  msg  <- recvExactX socket (unSize size)
  pure (pos, msg)

type Pos = Word64

type MergerState = (Map Pos (MVar ByteString), Maybe Pos)

mergerSetPos :: MVar MergerState -> Pos -> IO ()
mergerSetPos state pos = do
  modifyMVar_ state $ \ (table, _) ->
    pure (table, pure pos)

mergerInsert :: MVar MergerState -> MVar ByteString -> Pos -> IO ()
mergerInsert state vPush pos = do
  modifyMVar_ state (pure . first (Map.insert pos vPush))

mergerTransfer :: MVar MergerState -> MVar ByteString -> IO ()
mergerTransfer state vPull =
  modifyMVar_ state $ \ (table, maybePos) ->
    pure (table, maybePos) `fromMaybe` do
      pos <- maybePos
      (vPush, table') <- popMap pos table
      Just $ do
        takeMVar vPush >>= putMVar vPull
        pure (table', Nothing)

mergerPush :: MVar MergerState
           -> MVar ByteString
           -> MVar ByteString
           -> (Pos, ByteString)
           -> IO ()
mergerPush state vPull vPush (pos, msg) = do
  putMVar vPush msg
  mergerInsert state vPush pos
  mergerTransfer state vPull

mergerPull :: MVar MergerState -> MVar ByteString -> Pos -> IO ByteString
mergerPull state vPull pos = do
  mergerSetPos state pos
  forkIO_ (mergerTransfer state vPull)
  takeMVar vPull

mergerReceiver :: Socket
               -> MVar MergerState
               -> MVar ByteString
               -> MVar ByteString
               -> IO a
mergerReceiver socket state vPull vPush = do
  (pos, msg) <- recvChunkX socket
  mergerPush state vPull vPush (pos, msg)
  mergerReceiver socket state vPull vPush

mergerSender :: Socket
             -> MVar MergerState
             -> MVar ByteString
             -> Pos
             -> IO a
mergerSender socket state vPull pos = do
  msg <- mergerPull state vPull pos
  send socket msg
  mergerSender socket state vPull (pos + fromIntegral (B.length msg))

type HostService = (HostName, ServiceName)

type ProxiedHostService = (Maybe HostService, HostService)

serveReceptor :: (HostPreference, ServiceName)
              -> HostService
              -> IO ()
serveReceptor (bindHost, bindPort) destServ =
  serve bindHost bindPort $ \ (bindSocket, _) -> do
    _

serveTransporter :: (HostPreference, ServiceName)
                 -> [ProxiedHostService]
                 -> IO ()
serveTransporter _ [] = error "serveTransporter: no destination given"
serveTransporter (bindHost, bindPort) destServs =
  serve bindHost bindPort $ \ (bindSocket, _) -> do
    destServ0 : destServRest <- shuffleM destServs
    vConnID  <- newEmptyMVar
    vMessage <- newEmptyMVar
    splitterReceiver vMessage bindSocket 0
      `concurrently_`
      connectProxied destServ0 (initConn vMessage vConnID)
      `concurrently_`
       mapConcurrently_ (`connectProxied` joinConn vMessage vConnID)
                        destServRest
  where

    initConn vMessage vConnID (socket, _) = do
      sendMany socket [encode protocolVer, encode Initiate]
      Welcome <- recvThenDecodeX socket
      connID  <- recvThenDecodeX socket
      putMVar vConnID (connID :: ConnectionID)
      splitterSender vMessage socket

    joinConn vMessage vConnID (socket, _) = do
      connID <- readMVar vConnID
      sendMany socket [encode protocolVer, encode Join, encode connID]
      reply <- recvThenDecodeX socket
      case reply of
         Accept  -> splitterSender vMessage socket
         Invalid -> pure () -- teardown connection

type SplitterState = MVar (Pos, ByteString)

splitterSender :: SplitterState -> Socket -> IO ()
splitterSender vMessage socket = do
  takeMVar vMessage >>= sendChunk socket
  splitterSender vMessage socket

splitterReceiver :: SplitterState -> Socket -> Pos -> IO ()
splitterReceiver vMessage socket pos = do
  recvX socket maxChunkSize >>= putMVar vMessage . ((,) pos)
  splitterReceiver vMessage socket (pos + 1)

-- | Same as 'Int' except negative values are not allowed.
--   It is serialized in the same way as 'Word64'.
newtype Size = Size_ { unSize :: Int } deriving (Eq, Ord, Read, Show)

-- | Safe constructor for 'Size'.
size :: Int -> Maybe Size
size n | n < 0     = Nothing
       | otherwise = Just (Size_ n)

-- | Partial constructor for 'Size'.
sizeX :: Int -> Size
sizeX = fromJustE "sizeX: negative values are not allowed" . size

instance Serialize Size where
  put x = put (fromIntegral (intCast (unSize x) :: Int64) :: Word64)
  get = do
    n <- get
    maybeToAlternative (size =<< intCastMaybe (n :: Word64))

instance SizedSerialize Size where
  serializedSize _ = serializedSize ([] :: [Word64])

newtype ConnectionID
  = ConnectionID_ { unConnectionID :: ByteString }
  deriving (Eq, Ord, Read, Show, Typeable)

instance Serialize ConnectionID where
  get = sizedSerializeGet connectionID getBytes
  put = putByteString . unConnectionID

instance SizedSerialize ConnectionID where
  serializedSize _ = 8

connectionID :: ByteString -> Maybe ConnectionID
connectionID b
  | B.length b == serializedSize [connID] = Just connID
  | otherwise                             = Nothing
  where connID = ConnectionID_ b

generateConnectionID :: Map ConnectionID a -> IO ConnectionID
generateConnectionID m
  | Map.size m > maxConnections = throwIO TooManyConnectionsException
  | otherwise = generate
  where generate = do
          connID <- sizedSerializeGet connectionID getEntropy
          case Map.lookup connID m of
            Just _  -> generate
            Nothing -> pure connID

data Header
  = HeaderV1
  deriving (Eq, Ord, Read, Show, Typeable)

DERIVE_FROM_SERIALIZE_ENUM(Header)

instance SerializeEnum Header where
  serializeEnumInfo = generateSerializeEnumMap
    [ (HeaderV1, "imux001")
    ]

protocolVer :: Header
protocolVer = HeaderV1

data ClientCommand
  = Initiate
  | Join
  deriving (Eq, Ord, Read, Show, Typeable)

DERIVE_FROM_SERIALIZE_ENUM(ClientCommand)

instance SerializeEnum ClientCommand where
  serializeEnumInfo = generateSerializeEnumMap
    [ (Initiate, "initial\n")
    , (Join,     "join   \n")
    ]

data InitialReply
  = Welcome
  deriving (Eq, Ord, Read, Show, Typeable)

DERIVE_FROM_SERIALIZE_ENUM(InitialReply)

instance SerializeEnum InitialReply where
  serializeEnumInfo = generateSerializeEnumMap
    [ (Welcome, "welcome\n")
    ]

data JoinReply
  = Accept
  | Invalid
  deriving (Eq, Ord, Read, Show, Typeable)

DERIVE_FROM_SERIALIZE_ENUM(JoinReply)

instance SerializeEnum JoinReply where
  serializeEnumInfo = generateSerializeEnumMap
    [ (Accept,  "accept \n")
    , (Invalid, "invalid\n")
    ]

class Serialize a => SizedSerialize a where
  serializedSize :: proxy a -> Int

sizedSerializeGet :: (MonadPlus f, SizedSerialize a) =>
                     (ByteString -> Maybe a) -> (Int -> f ByteString) -> f a
sizedSerializeGet parse mget =
  case [] of
    proxy ->
      mget (serializedSize proxy) >>=
      maybeToAlternative . parse <&>
      (`asTypeOfProxy` proxy)

instance SizedSerialize Word64 where
  serializedSize = sizeOfProxy

type SerializeEnumInfo a = (Int, Map a ByteString, Map ByteString a)

class (Ord a, SizedSerialize a) => SerializeEnum a where
  serializeEnumInfo :: SerializeEnumInfo a

serializeEnumGet :: SerializeEnum a => Get a
serializeEnumGet = do
  b <- getBytes n
  maybeToAlternative (Map.lookup b m)
  where (n, _, m) = serializeEnumInfo

serializeEnumPut :: SerializeEnum a => Putter a
serializeEnumPut x = putByteString (fromMaybe e (Map.lookup x m))
  where (_, m, _) = serializeEnumInfo
        e = error "serializedEnumPut: value not in table"

serializeEnumSize :: SerializeEnum a => proxy a -> Int
serializeEnumSize proxy = n
  where (n, _, _) = narrow serializeEnumInfo proxy
        narrow :: SerializeEnumInfo a -> proxy a -> SerializeEnumInfo a
        narrow = const

generateSerializeEnumMap :: Ord a => [(a, ByteString)] -> SerializeEnumInfo a
generateSerializeEnumMap t = (getSize (B.length . snd <$> t), m, m')
  where (m, m') = generateBidiMap t
        getSize [] = 0
        getSize (s : rest)
          | s == s'   = s
          | otherwise = error ("generateSerializeEnumMap: " <>
                               "serialized values must have equal length")
          where s' = getSize rest

connectProxied :: ProxiedHostService -> ((Socket, SockAddr) -> IO a) -> IO a
connectProxied (Nothing, (host, port)) f = connect host port f
--connectProxied (Just (socksHost, socksPort), (host, port)) f = _
