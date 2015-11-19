{-# LANGUAGE ForeignFunctionInterface #-}

-- From http://stackoverflow.com/questions/12806053/get-terminal-width-haskell

module Blog.System.Terminal (getTermSize) where

import Foreign
import Foreign.C.Error
import Foreign.C.Types

#include <sys/ioctl.h>
#include <unistd.h>

-- Trick for calculating alignment of a type, taken from
-- http://www.haskell.org/haskellwiki/FFICookBook#Working_with_structs
#let alignment t = "%lu", (unsigned long)offsetof(struct {char x__; t (y__); }, y__)

-- @xpixel@ and @ypixel@ fields are unused,
-- so they've been omitted.
data WinSize = WinSize CUShort CUShort -- row, col

instance Storable WinSize where
  sizeOf _ = (#size struct winsize)
  alignment _ = (#alignment struct winsize) 
  peek ptr = WinSize
             <$> (#peek struct winsize, ws_row) ptr
             <*> (#peek struct winsize, ws_col) ptr
  poke ptr (WinSize row col) = do
    (#poke struct winsize, ws_row) ptr row
    (#poke struct winsize, ws_col) ptr col

foreign import ccall "sys/ioctl.h ioctl"
  ioctl :: CInt -> CInt -> Ptr WinSize -> IO CInt

-- | Return current number of (rows, columns) of the terminal.
getTermSize :: IO (Maybe (Int, Int))
getTermSize = with (WinSize 0 0) $ \ws -> do
  resetErrno
  ioctl (#const STDOUT_FILENO) (#const TIOCGWINSZ) ws
  err <- getErrno
  if isValidErrno err
    then do
      WinSize row col <- peek ws
      return $ Just (fromIntegral row, fromIntegral col)
    else return Nothing
  