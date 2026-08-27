-- haskell/spike, probe C -- the Haskell-specific version of the "ctx
-- pointer lifetime" question (Python probe 3, Go probe 2). GHC's GC is a
-- tracing, moving collector for the heap (unlike CPython's non-moving
-- refcounted heap) -- a raw address into an arbitrary Haskell value is not
-- something ordinary `Foreign.*` code can even obtain in the first place
-- (no direct equivalent of Go's `unsafe.Pointer(&x)` or a ctypes py_object
-- escape hatch), which is itself part of the finding, not just a detail --
-- see ../README.md. `Foreign.StablePtr` is GHC's purpose-built answer:
-- pins a value's IDENTITY reachable against GC (the direct equivalent of a
-- JNI global ref or a Python keep-alive registry entry) without needing the
-- value's own memory to stop moving.
--
-- This probe passes a StablePtr (cast to a Ptr ()) as listener_data,
-- forces aggressive GC + heap churn between every deadline tick (the same
-- amplification idea as every other spike's adversarial probe), and
-- confirms the pointed-to value's contents survive intact every time.
{-# LANGUAGE ForeignFunctionInterface #-}
module Main where

import Control.Concurrent (threadDelay)
import Control.Monad (when, replicateM_)
import Data.IORef
import Data.Int (Int32)
import Data.Word (Word32)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types
import Foreign.Marshal.Alloc (mallocBytes)
import Foreign.Marshal.Utils (fillBytes)
import Foreign.Ptr
import Foreign.StablePtr
import Foreign.Storable (pokeByteOff, peekByteOff)
import System.Exit (exitFailure)
import System.IO (hFlush, stdout)
import System.Mem (performGC)

foreign import ccall "zzdds_create_factory" c_zzdds_create_factory :: IO (Ptr ())
foreign import ccall "zzdds_factory_is_nil" c_zzdds_factory_is_nil :: Ptr () -> IO CBool
foreign import ccall "zzdds_destroy_factory" c_zzdds_destroy_factory :: Ptr () -> IO ()
foreign import ccall "zzdds_DomainParticipantFactory_as_DDS_DomainParticipantFactory"
  c_factory_as_dds :: Ptr () -> IO (Ptr ())
foreign import ccall "DDS_DomainParticipantFactory_create_participant"
  c_create_participant :: Ptr () -> Word32 -> Ptr () -> Ptr () -> Word32 -> IO (Ptr ())
foreign import ccall "zzdds_register_type_support"
  c_register_type_support :: Ptr () -> CString -> Ptr () -> Ptr () -> IO CInt
foreign import ccall "DDS_DomainParticipant_create_topic"
  c_create_topic :: Ptr () -> CString -> CString -> Ptr () -> Ptr () -> Word32 -> IO (Ptr ())
foreign import ccall "DDS_Topic_as_DDS_TopicDescription" c_topic_as_desc :: Ptr () -> IO (Ptr ())
foreign import ccall "DDS_DomainParticipant_create_subscriber"
  c_create_subscriber :: Ptr () -> Ptr () -> Ptr () -> Word32 -> IO (Ptr ())
foreign import ccall "DDS_DataReaderQos_default" c_reader_qos_default :: Ptr () -> IO ()
foreign import ccall "DDS_Subscriber_create_datareader"
  c_create_datareader :: Ptr () -> Ptr () -> Ptr () -> Ptr () -> Word32 -> IO (Ptr ())
foreign import ccall "spike_sizeof_reader_qos" c_sizeof_reader_qos :: IO CSize
foreign import ccall "spike_set_reader_deadline" c_set_reader_deadline :: Ptr () -> Int32 -> Word32 -> IO ()

type DeadlineCb = Ptr () -> Ptr () -> Ptr () -> IO ()
type ReleaseCb = Ptr () -> IO ()
foreign import ccall "wrapper" mkDeadlineCb :: DeadlineCb -> IO (FunPtr DeadlineCb)
foreign import ccall "wrapper" mkReleaseCb :: ReleaseCb -> IO (FunPtr ReleaseCb)

domainId :: Word32
domainId = 91

deadlineNsec :: Word32
deadlineNsec = 150000000

tickCount :: Int
tickCount = 12

magicWant :: Int
magicWant = 0x5EEDBEEF

listenerStructSize :: Int
listenerStructSize = 72

-- Heap churn: allocate and force evaluation of a lot of similarly-shaped
-- garbage between ticks, then GC, to put real pressure on the collector
-- to actually move/reclaim things rather than leaving memory untouched --
-- the same amplification idea as every other spike's adversarial probe.
heapChurn :: IO ()
heapChurn = do
  let junk = [replicate 64 (i :: Int) | i <- [1 .. 20000]]
  mapM_ (\xs -> length xs `seq` return ()) junk
  performGC

main :: IO ()
main = do
  checksRef <- newIORef (0 :: Int)
  mismatchesRef <- newIORef (0 :: Int)

  magicSP <- newStablePtr magicWant
  let ctxPtr = castStablePtrToPtr magicSP

  deadlineCbPtr <- mkDeadlineCb $ \_reader _status listenerData -> do
    let sp = castPtrToStablePtr listenerData :: StablePtr Int
    got <- deRefStablePtr sp
    modifyIORef' checksRef (+1)
    n <- readIORef checksRef
    let ok = got == magicWant
    putStrLn $ "[callback] check=" ++ show n ++ " got=" ++ show got
             ++ " want=" ++ show magicWant ++ " match=" ++ show ok
    when (not ok) $ modifyIORef' mismatchesRef (+1)
    hFlush stdout
    heapChurn

  releaseCbPtr <- mkReleaseCb $ \_ -> putStrLn "[callback] release_listener_data fired"

  factory <- c_zzdds_create_factory
  isNil <- c_zzdds_factory_is_nil factory
  when (isNil /= 0) $ putStrLn "FAIL: zzdds_create_factory nil" >> exitFailure
  ddsFactory <- c_factory_as_dds factory
  dp <- c_create_participant ddsFactory domainId nullPtr nullPtr 0
  when (dp == nullPtr) $ putStrLn "FAIL: create_participant" >> exitFailure

  withCString "SpikeType" $ \typeName ->
    withCString "SpikeTopic" $ \topicName -> do
      rc <- c_register_type_support dp typeName nullPtr nullPtr
      when (rc /= 0) $ putStrLn "FAIL: register_type_support" >> exitFailure
      topic <- c_create_topic dp topicName typeName nullPtr nullPtr 0
      when (topic == nullPtr) $ putStrLn "FAIL: create_topic" >> exitFailure
      topicDesc <- c_topic_as_desc topic
      sub <- c_create_subscriber dp nullPtr nullPtr 0
      when (sub == nullPtr) $ putStrLn "FAIL: create_subscriber" >> exitFailure

      qosSize <- c_sizeof_reader_qos
      qos <- mallocBytes (fromIntegral qosSize)
      c_reader_qos_default qos
      c_set_reader_deadline qos 0 deadlineNsec

      listener <- mallocBytes listenerStructSize
      fillBytes listener 0 listenerStructSize
      pokeByteOff listener 0 ctxPtr          -- listener_data = our StablePtr
      pokeByteOff listener 8 deadlineCbPtr
      pokeByteOff listener 64 releaseCbPtr

      reader <- c_create_datareader sub topicDesc qos listener 4
      when (reader == nullPtr) $ putStrLn "FAIL: create_datareader" >> exitFailure

      putStrLn $ "[main] reader created, waiting for " ++ show tickCount ++ " ticks with GC+churn between each..."
      hFlush stdout
      threadDelay (fromIntegral (tickCount + 3) * 200000)

      c_zzdds_destroy_factory factory
      freeStablePtr magicSP

      checks <- readIORef checksRef
      mismatches <- readIORef mismatchesRef
      putStrLn $ "[main] checks=" ++ show checks ++ " mismatches=" ++ show mismatches
      if checks < tickCount `div` 2
        then putStrLn "FAIL: too few ticks observed" >> exitFailure
        else if mismatches > 0
          then putStrLn "FAIL: StablePtr value corrupted under GC pressure -- should never happen" >> exitFailure
          else putStrLn "PASS"
