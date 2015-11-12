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
import Data.Traversable (for)
import Data.Tuple (swap)
import Data.Typeable (Typeable, typeRep)
import Data.Word (Word64, Word32)
import Foreign (Storable, sizeOf)
import Network (PortID(PortNumber))
import Network.Socket (ShutdownCmd(ShutdownSend), shutdown)
import Network.Simple.TCP
import Network.Socks5 (defaultSocksConf, socksConnectWith)
import System.IO
import System.Entropy (getEntropy)
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

-- | Signal the end of the stream by closing the writing half of the socket.
sendEOF :: Socket -> IO ()
sendEOF socket = shutdown socket ShutdownSend

portForward :: (HostPreference, Int)
            -> (HostName, Int)
            -> IO ()
portForward (bindHost, bindPort) (destHost, destPort) =
  serve   bindHost (show bindPort) $ \ (s,  _) ->
  connect destHost (show destPort) $ \ (s', _) ->
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
data ResourceExhaustedException =
  ResourceExhaustedException String
  deriving (Show, Typeable)
instance Exception ResourceExhaustedException

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
recvExactLT _      0   = pure mempty
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
recvChunkX socket = traceIO "recvChunkX" ()$ do
  pos  <- recvThenDecodeX socket
  size <- recvThenDecodeX socket
  when (unSize size > maxChunkSize) $
    throwIO (ResourceExhaustedException
             ("recvChunkX: chunk size too large (" <>
              show (unSize size) <> ")"))
  msg  <- recvExactX socket (unSize size)
  pure (pos, msg)

type Pos = Word64

type MergerState = (Map Pos (MVar ByteString), Maybe Pos)

type PullVar = MVar (Maybe ByteString)

mergerInitState :: MergerState
mergerInitState = (Map.empty, Nothing)

mergerSetPos :: MVar MergerState -> Pos -> IO ()
mergerSetPos state pos = do
  modifyMVar_ state $ \ (table, _) ->
    pure (table, pure pos)

mergerInsert :: MVar MergerState -> MVar ByteString -> Pos -> IO ()
mergerInsert state vPush pos = do
  modifyMVar_ state (pure . first (Map.insert pos vPush))

mergerTransfer :: MVar MergerState -> PullVar -> IO ()
mergerTransfer state vPull =
  modifyMVar_ state $ \ (table, maybePos) ->
    pure (table, maybePos) `fromMaybe` do
      pos <- maybePos
      (vPush, table') <- popMap pos table
      Just $ do
        takeMVar vPush >>= putMVar vPull . Just
        pure (table', Nothing)

mergerPush :: MVar MergerState
           -> PullVar
           -> MVar ByteString
           -> (Pos, ByteString)
           -> IO ()
mergerPush state vPull vPush (pos, msg) = do
  putMVar vPush msg
  mergerInsert state vPush pos
  mergerTransfer state vPull

mergerPull :: MVar MergerState -> PullVar -> Pos -> IO (Maybe ByteString)
mergerPull state vPull pos = do
  mergerSetPos state pos
  forkIO_ (mergerTransfer state vPull)
  takeMVar vPull

mergerReceiver :: Socket
               -> MVar MergerState
               -> PullVar
               -> MVar ByteString
               -> IO ()
mergerReceiver socket state vPull vPush = do
  result <- try (recvChunkX socket)
  case result of
    Left e -> let _ = e :: SomeException in print e
    Right (pos, msg) -> do
      mergerPush state vPull vPush (pos, msg)
      mergerReceiver socket state vPull vPush

mergerSender :: Socket -> MVar MergerState -> PullVar -> IO ()
mergerSender = mergerSenderResume 0

mergerSenderResume :: Pos
                   -> Socket
                   -> MVar MergerState
                   -> PullVar
                   -> IO ()
mergerSenderResume pos socket state vPull = do
  mMsg <- mergerPull state vPull pos
  case mMsg of
    Nothing  -> pure ()
    Just msg -> do
      send socket msg
      -- OLD: pos + fromIntegral (B.length msg)
      mergerSenderResume (pos + 1) socket state vPull

type SplitterState = MVar (Maybe (Pos, ByteString))

splitterStateNew :: IO SplitterState
splitterStateNew = newEmptyMVar

splitterSender :: SplitterState -> Socket -> IO ()
splitterSender vMessage socket =
  join $ mask $ \ unmask -> do
    mMsg <- takeMVar vMessage
    case mMsg of
      Just msg -> do
        unmask (sendChunk socket msg)
          `onException` putMVar vMessage mMsg
        pure (splitterSender vMessage socket)
      Nothing  -> do
        putMVar vMessage mMsg
        sendEOF socket
        pure (pure ())

splitterReceiver :: SplitterState -> Socket -> IO ()
splitterReceiver = splitterReceiverResume 0

splitterReceiverResume :: Pos -> SplitterState -> Socket -> IO ()
splitterReceiverResume pos vMessage socket = do
  mMsg <- recv socket maxChunkSize
  case mMsg of
    Nothing  -> putMVar vMessage Nothing
    Just msg -> do
      putMVar vMessage (Just (pos, msg))
      splitterReceiverResume (pos + 1) vMessage socket

type HostService = (HostName, Int)

type ProxiedHostService = (Maybe HostService, HostService)

-- type ConnTable = Map ConnectionID (Int {-refcount-})

serveReceptor :: (HostPreference, Int)
              -> ProxiedHostService
              -> IO ()
serveReceptor (bindHost, bindPort) destServ = traceIO "serveReceptor" (bindHost, bindPort, destServ) $ do
  vConnTable <- newMVar (Map.empty)
  serve bindHost (show bindPort) $ \ (socket, _) -> do
    header <- recvThenDecodeX socket
    case header of
      HeaderV1 -> pure ()
    command <- recvThenDecodeX socket
    case command of
      Initiate -> do
        vPState <- (,) <$> newEmptyMVar <*> newMVar mergerInitState
        splitterState <- splitterStateNew
        let connInfo = (1, (vPState, splitterState))
        connTable <- takeMVar vConnTable
        connID <- generateConnectionID connTable
                  `onException` putMVar vConnTable connTable
        let connTable' = Map.insert connID connInfo connTable
        forkIO_ (upstreamThread vPState splitterState vConnTable connID)
        putMVar vConnTable connTable'
        sendMany socket [encode Welcome, encode connID]
        vPush <- newEmptyMVar
        downstreamThread splitterState vPState vPush socket
          `finally` decref vConnTable connID
      Join -> do
        connID <- recvThenDecodeX socket
        connTable <- takeMVar vConnTable
        case Map.lookup connID connTable of
          Nothing -> do
            putMVar vConnTable connTable
            send socket (encode Invalid)
          Just (_, (vPState, splitterState)) -> do
            -- Q. is the ref counter REALLY necessary?
            -- A. yes it is: we need it to gracefully terminate the mergerSender
            putMVar vConnTable (Map.adjust (first (+ (1 :: Int))) connID connTable)
            send socket (encode Accept)
            vPush <- newEmptyMVar
            downstreamThread splitterState vPState vPush socket
              `finally` decref vConnTable connID
  where

    decref vConnTable connID =
      mask_ . modifyMVar_ vConnTable $ \ connTable ->
        case Map.lookup connID connTable of
          Nothing -> pure connTable
          Just (count, info)
            | count > 1 -> pure (Map.adjust (first pred) connID connTable)
            | otherwise -> do
                finalizer info
                pure (Map.delete connID connTable)

    finalizer ((vPull, _), _) = putMVar vPull Nothing

    upstreamThread (vPull, vState) splitterState vConnTable connID =
      connectProxied destServ (upstream (vPull, vState) splitterState)
      `finally` modifyMVar_ vConnTable (pure . Map.delete connID)

    downstreamThread splitterState vPState vPush socket =
      downstream vPState vPush splitterState socket

    upstream (vPull, vState) splitterState socket =
      splitterReceiver splitterState socket `concurrently_`
      mergerSender socket vState vPull

    downstream (vPull, vState) vPush splitterState socket =
      splitterSender splitterState socket `concurrently_`
      mergerReceiver socket vState vPull vPush

serveTransporter :: (HostPreference, Int)
                 -> [ProxiedHostService]
                 -> IO ()
serveTransporter _ [] = error "serveTransporter: no destination given"
serveTransporter (bindHost, bindPort) destServs =
  serve bindHost (show bindPort) $ \ (bindSocket, _) -> do
    vConnID <- newMVar (Nothing :: Maybe ConnectionID)
    splitterState <- splitterStateNew
    vPState <- (,) <$> newEmptyMVar <*> newMVar mergerInitState
    svPushs <- for destServs $ \ x -> (,) x <$> newEmptyMVar
    concurrently_
      (downstream vPState splitterState bindSocket)
      (mapConcurrently_ (upstreamThread vConnID splitterState vPState) svPushs)
  where

    upstreamThread vConnID splitterState vPState (serv, vPush) =
      connectProxied serv $ \ socket -> do
        send socket (encode protocolVer)
        reply <- modifyMVar vConnID $ \ mConnID ->
          case mConnID of
            Nothing -> do
              send socket (encode Initiate)
              Welcome <- recvThenDecodeX socket
              connID <- recvThenDecodeX socket
              pure (Just connID, Accept)
            Just connID -> do
              sendMany socket [encode Join, encode connID]
              reply <- recvThenDecodeX socket
              pure (mConnID, reply)
        case reply of
          Accept  -> upstream vPState vPush splitterState socket
          Invalid -> pure () -- tear down connection

    downstream (vPull, vState) splitterState socket =
      splitterReceiver splitterState socket `concurrently_`
      mergerSender socket vState vPull

    upstream (vPull, vState) vPush splitterState socket =
      splitterSender splitterState socket `concurrently_`
      mergerReceiver socket vState vPull vPush

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
  | Map.size m > maxConnections =
      throwIO (ResourceExhaustedException
              "generateConnectionID: too many ongoing connections")
  | otherwise = generate
  where generate = do
          connID <- sizedSerializeGet connectionID getEntropy
          if Map.member connID m
            then generate
            else pure connID

data Header
  = HeaderV1
  deriving (Eq, Ord, Read, Show, Typeable)

DERIVE_FROM_SERIALIZE_ENUM(Header)

instance SerializeEnum Header where
  serializeEnumInfo = generateSerializeEnumMap
    [ (HeaderV1, "imux001\n")
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
        getSize (s : []) = s
        getSize (s : rest)
          | s == s'   = s
          | otherwise = error ("generateSerializeEnumMap: " <>
                               "serialized values must have equal length")
          where s' = getSize rest

connectProxied :: ProxiedHostService -> (Socket -> IO a) -> IO a
connectProxied (Nothing, (host, port)) action =
--  traceIO "connect" (host, port) $
  connect host (show port) (action . fst)
connectProxied (Just (socksHost, socksPort), (host, port)) action =
  bracket
    (socksConnectWith socksConf host (PortNumber (fromIntegral port)))
    closeSock
    action
  where socksConf = defaultSocksConf socksHost (fromIntegral socksPort)
