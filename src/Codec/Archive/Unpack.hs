module Codec.Archive.Unpack ( hsEntries
                            , unpackEntriesFp
                            ) where

import           Codec.Archive.Foreign
import           Codec.Archive.Types
import           Control.Monad         (void)
import qualified Data.ByteString       as BS
import           Foreign.C.String
import           Foreign.Marshal.Alloc (alloca)
import           Foreign.Ptr           (Ptr)
import           Foreign.Storable      (Storable (..))
import           System.FilePath       ((</>))

readEntry :: Ptr Archive -> Ptr ArchiveEntry -> IO Entry
readEntry a entry = do
    fp <- peekCString =<< archive_entry_pathname entry
    perms <- archive_entry_perm entry
    contents <- readContents a entry
    owner <- readOwnership entry
    times <- readTimes entry
    pure $ Entry fp contents perms owner times

getHsEntry :: Ptr Archive -> IO (Maybe Entry)
getHsEntry a = do
    entry <- getEntry a
    case entry of
        Nothing -> pure Nothing
        Just x  -> Just <$> readEntry a x

hsEntries :: Ptr Archive -> IO [Entry]
hsEntries a = do
    next <- getHsEntry a
    case next of
        Nothing -> pure []
        Just x  -> (x:) <$> hsEntries a

-- | Unpack an archive in a given directory
unpackEntriesFp :: Ptr Archive -> FilePath -> IO ()
unpackEntriesFp a fp = do
    res <- getEntry a
    case res of
        Nothing -> pure ()
        Just x  -> do
            preFile <- archive_entry_pathname x
            file <- peekCString preFile
            let file' = fp </> file
            withCString file' $ \fileC ->
                archive_entry_set_pathname x fileC
            void $ archive_read_extract a x archiveExtractTime
            archive_entry_set_pathname x preFile
            void $ archive_read_data_skip a
            unpackEntriesFp a fp

readBS :: Ptr Archive -> IO BS.ByteString
readBS a =
    alloca $ \buff ->
    alloca $ \sz ->
    alloca $ \offset -> do
        void $ archive_read_data_block a buff sz offset
        cstr <- peek buff
        strSz <- peek sz
        BS.packCStringLen (cstr, fromIntegral strSz)

readContents :: Ptr Archive -> Ptr ArchiveEntry -> IO EntryContent
readContents a entry = go =<< archive_entry_filetype entry
    where go ft@(FileType n) | ft == regular = NormalFile <$> readBS a
                | ft == symlink = Symlink <$> (peekCString =<< archive_entry_symlink entry)
                | ft == directory = pure Directory
                | otherwise = error ("Unsupported filetype " ++ show n)

readOwnership :: Ptr ArchiveEntry -> IO Ownership
readOwnership entry =
    Ownership
        <$> (peekCString =<< archive_entry_uname entry)
        <*> (peekCString =<< archive_entry_gname entry)
        <*> archive_entry_uid entry
        <*> archive_entry_gid entry

readTimes :: Ptr ArchiveEntry -> IO ModTime
readTimes entry =
    (,) <$> archive_entry_mtime entry <*> archive_entry_mtime_nsec entry

getEntry :: Ptr Archive -> IO (Maybe (Ptr ArchiveEntry))
getEntry a = alloca $ \ptr -> do
    let done res = not (res == archiveOk || res == archiveRetry)
    stop <- done <$> archive_read_next_header a ptr
    if stop
        then pure Nothing
        else Just <$> peek ptr

