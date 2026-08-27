-- haskell/spike, probe A/B -- does a zzdds-internal thread (never created
-- by, or announced to, the GHC RTS) correctly deliver a listener callback
-- into Haskell, and is the threaded RTS (`-threaded`) actually required for
-- that, or just recommended?
--
-- Same cheapest-possible trigger as the Python/Go spikes: a DataReader with
-- a short DEADLINE period on a topic nobody writes to, waiting for zzdds's
-- per-participant timer thread to fire on_requested_deadline_missed via a
-- `foreign import ccall "wrapper"`-generated function pointer, entirely
-- unprompted -- no writer, no data flow, no second process.
--
-- This same source is built TWICE (see ../README.md's Setup) -- once with
-- `-threaded`, once without -- to get real evidence of the documented claim
-- that a foreign OS thread calling into GHC-compiled code needs the
-- threaded RTS, rather than assuming it from the GHC manual alone.
--
-- No .cabal file, no external packages -- only `base`, hand-declared FFI
-- imports against zzdds's C-ABI (no header include mechanism in GHC's FFI
-- the way cgo has one), same "hand-declare just what's needed" approach as
-- the Python (ctypes) and Rust (extern "C") spikes.
{-# LANGUAGE ForeignFunctionInterface #-}
module Main where

import Control.Concurrent (threadDelay, myThreadId)
import Control.Monad (when, unless)
import Data.IORef
import Data.Int (Int32)
import Data.Word (Word32)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types
import Foreign.Marshal.Alloc (mallocBytes, free)
import Foreign.Marshal.Utils (fillBytes)
import Foreign.Ptr
import Foreign.StablePtr
import Foreign.Storable (pokeByteOff, peekByteOff)
import System.Exit (exitFailure)
import System.IO (hFlush, stdout)

foreign import ccall "zzdds_create_factory"
  c_zzdds_create_factory :: IO (Ptr ())
-- NOTE: this returns C `bool` (1 byte, per the SysV ABI), NOT `int` (4
-- bytes). Declaring it as CInt here (an earlier version of this file did)
-- compiles fine and silently captures whatever garbage happens to be in
-- the upper 3 bytes of the return register along with the real 1-byte
-- result -- confirmed live: it read back as 871572480 for what was
-- actually a valid, non-nil factory pointer. CBool is the correct mapping.
-- See ../README.md's Findings for why this is worth flagging for the
-- review, not just fixing quietly.
foreign import ccall "zzdds_factory_is_nil"
  c_zzdds_factory_is_nil :: Ptr () -> IO CBool
foreign import ccall "zzdds_destroy_factory"
  c_zzdds_destroy_factory :: Ptr () -> IO ()
foreign import ccall "zzdds_DomainParticipantFactory_as_DDS_DomainParticipantFactory"
  c_factory_as_dds :: Ptr () -> IO (Ptr ())
foreign import ccall "DDS_DomainParticipantFactory_create_participant"
  c_create_participant :: Ptr () -> Word32 -> Ptr () -> Ptr () -> Word32 -> IO (Ptr ())
foreign import ccall "zzdds_register_type_support"
  c_register_type_support :: Ptr () -> CString -> Ptr () -> Ptr () -> IO CInt
foreign import ccall "DDS_DomainParticipant_create_topic"
  c_create_topic :: Ptr () -> CString -> CString -> Ptr () -> Ptr () -> Word32 -> IO (Ptr ())
foreign import ccall "DDS_Topic_as_DDS_TopicDescription"
  c_topic_as_desc :: Ptr () -> IO (Ptr ())
foreign import ccall "DDS_DomainParticipant_create_subscriber"
  c_create_subscriber :: Ptr () -> Ptr () -> Ptr () -> Word32 -> IO (Ptr ())
foreign import ccall "DDS_DataReaderQos_default"
  c_reader_qos_default :: Ptr () -> IO ()
foreign import ccall "DDS_Subscriber_create_datareader"
  c_create_datareader :: Ptr () -> Ptr () -> Ptr () -> Ptr () -> Word32 -> IO (Ptr ())

foreign import ccall "spike_sizeof_reader_qos"
  c_sizeof_reader_qos :: IO CSize
foreign import ccall "spike_set_reader_deadline"
  c_set_reader_deadline :: Ptr () -> Int32 -> Word32 -> IO ()

-- The callback type. `safe` (the default for a plain `foreign import ccall`
-- without `unsafe`) so the RTS can properly schedule around a call that,
-- from zzdds's side, originates on a thread the RTS doesn't manage.
type DeadlineCb = Ptr () -> Ptr () -> Ptr () -> IO ()
type ReleaseCb = Ptr () -> IO ()

foreign import ccall "wrapper"
  mkDeadlineCb :: DeadlineCb -> IO (FunPtr DeadlineCb)
foreign import ccall "wrapper"
  mkReleaseCb :: ReleaseCb -> IO (FunPtr ReleaseCb)

domainId :: Word32
domainId = 90

deadlinePeriodNsec :: Word32
deadlinePeriodNsec = 150000000 -- 150ms

runMicros :: Int
runMicros = 8 * 1000 * 1000

listenerStructSize :: Int
listenerStructSize = 72 -- 9 pointer-sized fields, x86_64

main :: IO ()
main = do
  tid <- myThreadId
  putStrLn $ "[main] main ThreadId=" ++ show tid
  hFlush stdout

  firesRef <- newIORef (0 :: Int)
  releasesRef <- newIORef (0 :: Int)
  seenTidsRef <- newIORef ([] :: [String])

  deadlineCbPtr <- mkDeadlineCb $ \_reader status _listenerData -> do
    cbTid <- myThreadId
    totalCount <- peekByteOff status 0 :: IO Int32
    modifyIORef' firesRef (+1)
    modifyIORef' seenTidsRef (show cbTid :)
    n <- readIORef firesRef
    putStrLn $ "[callback] fired n=" ++ show n ++ " total_count=" ++ show totalCount
             ++ " ThreadId=" ++ show cbTid ++ " same_as_main=" ++ show (cbTid == tid)
    hFlush stdout

  releaseCbPtr <- mkReleaseCb $ \_listenerData -> do
    modifyIORef' releasesRef (+1)
    putStrLn "[callback] release_listener_data fired"
    hFlush stdout

  factory <- c_zzdds_create_factory
  isNil <- c_zzdds_factory_is_nil factory
  when (isNil /= 0) $ do
    putStrLn "FAIL: zzdds_create_factory() returned nil"
    exitFailure

  ddsFactory <- c_factory_as_dds factory
  dp <- c_create_participant ddsFactory domainId nullPtr nullPtr 0
  when (dp == nullPtr) $ do
    putStrLn "FAIL: create_participant() failed"
    exitFailure

  withCString "SpikeType" $ \typeName ->
    withCString "SpikeTopic" $ \topicName -> do
      rc <- c_register_type_support dp typeName nullPtr nullPtr
      when (rc /= 0) $ do
        putStrLn $ "FAIL: register_type_support rc=" ++ show rc
        exitFailure

      topic <- c_create_topic dp topicName typeName nullPtr nullPtr 0
      when (topic == nullPtr) $ do
        putStrLn "FAIL: create_topic() failed"
        exitFailure
      topicDesc <- c_topic_as_desc topic

      sub <- c_create_subscriber dp nullPtr nullPtr 0
      when (sub == nullPtr) $ do
        putStrLn "FAIL: create_subscriber() failed"
        exitFailure

      qosSize <- c_sizeof_reader_qos
      qos <- mallocBytes (fromIntegral qosSize)
      c_reader_qos_default qos
      c_set_reader_deadline qos 0 deadlinePeriodNsec

      listener <- mallocBytes listenerStructSize
      fillBytes listener 0 listenerStructSize
      pokeByteOff listener 8 deadlineCbPtr   -- on_requested_deadline_missed
      pokeByteOff listener 64 releaseCbPtr   -- release_listener_data

      reader <- c_create_datareader sub topicDesc qos listener 4 -- DDS_REQUESTED_DEADLINE_MISSED_STATUS
      when (reader == nullPtr) $ do
        putStrLn "FAIL: create_datareader() failed"
        exitFailure

      putStrLn $ "[main] reader created, waiting " ++ show (runMicros `div` 1000000) ++ "s for callbacks..."
      hFlush stdout
      threadDelay runMicros

      fires <- readIORef firesRef
      releases <- readIORef releasesRef
      seenTids <- readIORef seenTidsRef
      let distinctTids = length (dedupe seenTids)
      putStrLn $ "[main] fires=" ++ show fires ++ " releases_so_far=" ++ show releases
               ++ " distinct_callback_threadids=" ++ show distinctTids

      if fires < 5
        then do
          putStrLn "FAIL: expected >= 5 deadline-missed callbacks in 8s"
          exitFailure
        else do
          c_zzdds_destroy_factory factory
          finalReleases <- readIORef releasesRef
          putStrLn $ "[main] teardown done; release_listener_data fired " ++ show finalReleases ++ " time(s)"
          putStrLn "PASS"
  where
    dedupe = foldr (\x acc -> if x `elem` acc then acc else x : acc) []
