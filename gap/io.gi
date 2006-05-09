#############################################################################
##
#W  io.gi               GAP 4 package `IO'                    Max Neunhoeffer
##
#Y  Copyright (C)  2005,  Lehrstuhl D fuer Mathematik,  RWTH Aachen,  Germany
##
##  This file contains functions mid level IO providing buffering and
##  easier access from the GAP level. 
##

################################
# First look after our C part: #
################################

# load kernel function if it is installed:
if (not IsBound(IO)) and ("io" in SHOW_STAT()) then
  # try static module
  LoadStaticModule("io");
fi;
if (not IsBound(IO)) and
   (Filename(DirectoriesPackagePrograms("io"), "io.so") <> fail) then
  LoadDynamicModule(Filename(DirectoriesPackagePrograms("io"), "io.so"));
fi;

#####################################
# Then some technical preparations: #
#####################################

# The family:

BindGlobal( "FileFamily", NewFamily("FileFamily", IsFile) );

# The type:
InstallValue( FileType,
  NewType(FileFamily, IsFile and IsAttributeStoringRep));


# one can now create objects by doing:
# r := rec( ... )
# Objectify(FileType,r);

IO.LineEndChars := "\n";
IO.LineEndChar := '\n';
if ARCH_IS_MAC() then
    IO.LineEndChars := "\r";
    IO.LineEndChar := '\r';
elif ARCH_IS_WINDOWS() then
    IO.LineEndChars := "\r\n";
fi;

###########################################################################
# Now the functions to create and work with objects in the filter IsFile: #
###########################################################################

InstallGlobalFunction(IO_WrapFD,function(fd,rbuf,wbuf)
  # fd: a small integer (a file descriptor).
  # rbuf: either false (for unbuffered) or a size for the read buffer size
  # wbuf: either false (for unbuffered) or a size for the write buffer size
  # rbuf can also be a string in which case fd must be -1 and we get
  # a File object that reads from that string.
  # wbuf can also be a string in which case fd must be -1 and we get
  # a File object that writes to that string by appending.
  local f;
  f := rec(fd := fd, 
           rbufsize := rbuf, 
           wbufsize := wbuf,
           closed := false);
  if f.rbufsize <> false then
      if IsInt(f.rbufsize) then
          f.rbuf := "";  # this can grow up to r.bufsize
          f.rpos := 1;
          f.rdata := 0;  # nothing in the buffer up to now
      else
          f.fd := -1;
          f.rbuf := f.rbufsize;
          f.rbufsize := Length(f.rbuf);
          f.rpos := 1;
          f.rdata := Length(f.rbuf);
      fi;
  fi;
  if f.wbufsize <> false then
      if IsInt(f.wbufsize) then
          f.wbuf := "";
          f.wdata := 0;  # nothing in the buffer up to now
      else
          f.fd := -1;
          f.wbuf := f.wbufsize;
          f.wbufsize := infinity;
          f.wdata := Length(f.wbuf);
      fi;
  fi;
  return Objectify(FileType,f);
end );

IO.DefaultBufSize := 65536;

# A convenience function for files on disk:
InstallGlobalFunction(IO_File, function( arg )
  # arguments: filename [,mode]
  # filename is a string and mode can be:
  #   "r" : open for reading only (default)
  #   "w" : open for writing only, possibly creating/truncating
  #   "a" : open for appending
  local fd,filename,mode;
  if Length(arg) = 1 then
      filename := arg[1];
      mode := "r";
  elif Length(arg) = 2 then
      filename := arg[1];
      mode := arg[2];
  else
      Error("IO: Usage: IO_File( filename [,mode] ) with IsString(filename)");
  fi;
  if not(IsString(filename)) and not(IsString(mode)) then
      Error("IO: Usage: IO_File( filename [,mode] ) with IsString(filename)");
  fi;
  if mode = "r" then
      fd := IO_open(filename,IO.O_RDONLY,0);
      if fd = fail then return fail; fi;
      return IO_WrapFD(fd,IO.DefaultBufSize,false);
  elif mode = "w" then
      fd := IO_open(filename,IO.O_CREAT+IO.O_WRONLY+IO.O_TRUNC,
                    IO.S_IRUSR+IO.S_IWUSR+IO.S_IRGRP+IO.S_IWGRP+
                    IO.S_IROTH+IO.S_IWOTH);
      if fd = fail then return fail; fi;
      return IO_WrapFD(fd,false,IO.DefaultBufSize);
  elif mode = "a" then
      fd := IO_open(filename,IO.O_APPEND+IO.O_WRONLY,0);
      if fd = fail then return fail; fi;
      return IO_WrapFD(fd,false,IO.DefaultBufSize);
  else
      Error("IO: Mode not supported!");
  fi;
end );

# A nice View method:
InstallMethod( ViewObj, "for IsFile objects", [IsFile],
  function(f)
    if f!.closed then
        Print("<closed file fd=");
    else
        Print("<file fd=");
    fi;
    Print(f!.fd);
    if f!.rbufsize <> false then
        Print(" rbufsize=",f!.rbufsize," rpos=",f!.rpos," rdata=",f!.rdata);
    fi;
    if f!.wbufsize <> false then
        Print(" wbufsize=",f!.wbufsize," wdata=",f!.wdata);
    fi;
    Print(">");
  end);

# Now a convenience function for closing:
InstallGlobalFunction( IO_Close, function( f )
  # f must be an object of type IsFile
  if not(IsFile(f)) or f!.closed then
      return fail;
  fi;
  # First flush if necessary:
  if f!.wbufsize <> false and f!.wdata <> 0 then
      IO_Flush( f );
  fi;
  f!.closed := true;
  f!.rbufsize := false;
  f!.wbufsize := false;
  # to free the memory for the buffer
  f!.rbuf := fail;
  f!.wbuf := fail;
  if f!.fd <> -1 then
      return IO_close(f!.fd);
  else
      return true;
  fi;
end );

# The buffered read functionality:
InstallGlobalFunction( IO_Read, function( arg )
  # arguments: f [,length]
  # f must be an object of type IsFile
  # length is a maximal length
  # Reads up to length bytes or until end of file if length is not specified.
  local amount,bytes,f,len,res;
  if Length(arg) = 1 then
      f := arg[1];
      len := -1;
  elif Length(arg) = 2 then
      f := arg[1];
      len := arg[2];
  else
      Error("Usage: IO_Read( f [,len] ) with IsFile(f) and IsInt(len)");
  fi;
  if not(IsFile(f)) or not(IsInt(len)) then
      Error("Usage: IO_Read( f [,len] ) with IsFile(f) and IsInt(len)");
  fi;
  if f!.closed then
      Error("Tried to read from closed file.");
  fi;
  if len = -1 then   
      # Read until end of file:
      if f!.rbufsize <> false and f!.rdata <> 0 then   # we read buffered:
          # First empty the buffer:
          res := f!.rbuf{[f!.rpos..f!.rpos+f!.rdata-1]};
          f!.rpos := 1;
          f!.rdata := 0;
      else
          res := "";
      fi;   
      # Now read on:
      if f!.fd = -1 then
          return res;
      fi;
      repeat
          bytes := IO_read(f!.fd,res,Length(res),f!.rbufsize);
          if bytes = fail then return fail; fi;
      until bytes = 0;
      return res;
  else   
      res := "";
      # First the case of no buffer:
      if f!.rbufsize = false then
          while Length(res) < len do
              bytes := IO_read(f!.fd,res,Length(res),len - Length(res));
              if bytes = fail then
                  return fail;
              fi;
              if bytes = 0 then
                  return res;
              fi;
          od;
          return res;
      fi;
      # read up to len bytes, using our buffer:     
      while Length(res) < len do
          # First empty the buffer:
          if f!.rdata > len - Length(res) then   # more data available
              amount := len - Length(res);
              Append(res,f!.rbuf{[f!.rpos..f!.rpos+amount-1]});
              f!.rpos := f!.rpos + amount;
              f!.rdata := f!.rdata - amount;
              return res;
          else
              Append(res,f!.rbuf{[f!.rpos..f!.rpos+f!.rdata-1]});
              f!.rpos := 1;
              f!.rdata := 0;
          fi;
          if f!.fd = -1 then
              return res;
          fi;
          if len - Length(res) > f!.rbufsize then   
              # In this case we read the whole thing:
              bytes := IO_read(f!.fd,res,Length(res),len - Length(res));
              if bytes = fail then 
                  return fail;
              elif bytes = 0 then 
                  return res;
              fi;
          fi; 
          # Now the buffer is empty, so refill it:
          bytes := IO_read(f!.fd,f!.rbuf,0,f!.rbufsize);
          if bytes = fail then
              return fail;
          elif bytes = 0 then
              return res;
          fi;
          f!.rdata := bytes;
      od;
      return res;
  fi;
end );

InstallGlobalFunction( IO_ReadLine, function( f )
  # f must be an object of type IsFile
  # The IO.LineEndChars are not removed at the end
  local bytes,pos,res;
  if not(IsFile(f)) then
      Error("Usage: IO_ReadLine( f ) with IsFile(f)");
  fi;
  if f!.closed then
      Error("Tried to read from closed file.");
  fi;
  if f!.rbufsize = false then
      Error("IO: Readline not possible for unbuffered files.");
  fi;
  res := "";
  while true do
      # First try to find a line end within the buffer:
      pos := Position(f!.rbuf,IO.LineEndChar,f!.rpos-1);
      if pos <> fail and pos < f!.rpos + f!.rdata then
          # The line is completely within the buffer
          Append(res,f!.rbuf{[f!.rpos..pos]});
          f!.rdata := f!.rdata - (pos + 1 - f!.rpos);
          f!.rpos := pos + 1;
          return res;
      else
          Append(res,f!.rbuf{[f!.rpos..f!.rpos + f!.rdata - 1]});
          f!.rpos := 1;
          f!.rdata := 0;
          if f!.fd = -1 then
              return res;
          fi;
          # Now read more data into buffer:
          bytes := IO_read(f!.fd,f!.rbuf,0,f!.rbufsize);
          if bytes = fail then
              return fail;
          fi;
          if bytes = 0 then   # we are at end of file
              return res;
          fi;
          f!.rdata := bytes;
      fi;
  od;
end );

InstallGlobalFunction( IO_ReadLines, function (arg)
  # arguments: f [,maxlines]
  # f must be an object of type IsFile
  # maxlines is the maximal number of lines read
  # Reads lines (max. maxlines or until end of file) and returns a list
  # of strings, which are the lines.
  local f,l,li,max;
  if Length(arg) = 1 then
      f := arg[1];
      max := infinity;
  elif Length(arg) = 2 then
      f := arg[1];
      max := arg[2];
  else
      Error("Usage: IO_ReadLines( f [,max] ) with IsFile(f) and IsInt(max)");
  fi;
  if not(IsFile(f)) or not(IsInt(max) or max = infinity) then
      Error("Usage: IO_ReadLines( f [,max] ) with IsFile(f) and IsInt(max)");
  fi;
  if f!.closed then
      Error("Tried to read from closed file.");
  fi;
  li := [];
  while Length(li) < max do
      l := IO_ReadLine(f);
      if l = fail then 
          return fail;
      fi;
      if Length(l) = 0 then
          return li;
      fi;
      Add(li,l);
  od;
  return li;
end );

# The buffered write functionality:
InstallGlobalFunction( IO_Write, function( arg )
  # arguments: f {,things ... }
  # f must be an object of type IsFile
  # all other arguments: either they are strings, in which case they are
  # written directly, otherwise they are converted to strings with "String"
  # and the result is being written.
  local bytes,f,i,pos,pos2,st,sumbytes;
  if Length(arg) < 2 or not(IsFile(arg[1])) then
      Error("Usage: IO_Write( f ,things ... ) with IsFile(f)");
  fi;
  f := arg[1];
  if f!.closed then
      Error("Tried to write on closed file.");
  fi;
  if Length(arg) = 2 and IsString(arg[2]) then
      # This is the main buffered Write functionality, all else delegates here:
      st := arg[2];
      # Do we buffer?
      if f!.wbufsize = false then
          pos := 0;
          while pos < Length(st) do
              bytes := IO_write(f!.fd,st,pos,Length(st));
              if bytes = fail then
                  return fail;
              fi;
              pos := pos + bytes;
          od;
          return Length(st);   # this indicates success
      else   # we do buffering:
          pos := 0;
          while pos < Length(st) do
              # First fill the buffer:
              if Length(st) - pos + f!.wdata < f!.wbufsize then
                  f!.wbuf{[f!.wdata+1..f!.wdata+Length(st)-pos]} := 
                          st{[pos+1..Length(st)]};
                  f!.wdata := f!.wdata + Length(st) - pos;
                  return Length(st);
              else
                  f!.wbuf{[f!.wdata+1..f!.wbufsize]} := 
                          st{[pos+1..pos+f!.wbufsize-f!.wdata]};
                  pos := pos + f!.wbufsize - f!.wdata;
                  f!.wdata := f!.wbufsize;
                  # Now the buffer is full and pos is still < Length(st)!
              fi;
              # Write out the buffer:
              pos2 := 0;
              while pos2 < f!.wbufsize do
                  bytes := IO_write(f!.fd,f!.wbuf,pos2,f!.wbufsize-pos2);
                  if bytes = fail then
                      return fail;
                  fi;
                  pos2 := pos2 + bytes;
              od;
              f!.wdata := 0;
              # Perhaps we can write a big chunk:
              if Length(st)-pos > f!.wbufsize then
                  bytes := IO_write(f!.fd,st,pos,Length(st)-pos);
                  if bytes = fail then
                      return fail;
                  fi;
                  pos := pos + bytes;
              fi;
          od;
          return Length(st);
      fi;
  fi;
  sumbytes := 0;
  for i in [2..Length(arg)] do
      if IsString(arg[i]) then
          st := arg[i];
      else
          st := String(arg[i]);
      fi;
      bytes := IO_Write(f,st);   # delegate to above
      if bytes = fail then
          return fail;
      fi;
      sumbytes := sumbytes + bytes;
  od;
  return sumbytes;
end );

InstallGlobalFunction( IO_WriteLine, function( arg )
  # The same as IO_write, except that a line end is written in the end
  # and the buffer is flushed afterwards.
  local res;
  Add(arg,IO.LineEndChars);
  res := CallFuncList( IO_Write, arg );
  if res = fail then
      return fail;
  fi;
  if IO_Flush(arg[1]) = fail then
      return fail;
  else
      return res;
  fi;
end );

InstallGlobalFunction( IO_WriteLines, function( f, l )
  # f must be an object of type IsFile
  # l must be a list. Calls IO_Write( f, o, IO.LineEndChars ) for all o in l.
  local o,res,written;
  if not(IsFile(f)) or not(IsList(l)) then
      Error("Usage: IO_WriteLines( f, l ) with IsFile(f) and IsList(l)");
  fi;
  written := 0;
  for o in l do
      res := IO_Write(f, o, IO.LineEndChars);
      if res = fail then
          return fail;
      fi;
      written := written + res;
  od;
  if IO_Flush(f) = fail then
      return fail;
  else
      return written;
  fi;
end );

InstallGlobalFunction( IO_Flush, function( f )
  local res;
  if not(IsFile(f)) then
      Error("Usage: IO_Flush( f ) with IsFile(f)");
  fi;
  if f!.fd = -1 then  # Nothing to do for string Files
      return true;
  fi;
  while f!.wbufsize <> false and f!.wdata <> 0 do
      res := IO_write( f!.fd, f!.wbuf, 0, f!.wdata );
      if res = fail then
          return fail;
      fi;
      f!.wdata := f!.wdata - res;
  od;
  return true;
end );
 
# Allow access to the file descriptor:
InstallGlobalFunction( IO_GetFD, function(f)
  if not(IsFile(f)) then
      Error("Usage: IO_GetFD( f ) with IsFile(f)");
  fi;
  return f!.fd;
end );

# Allow access to the buffers:
InstallGlobalFunction( IO_GetWBuf, function(f)
  if not(IsFile(f)) then
      Error("Usage IO_GetWBuf( f ) with IsFile(f)");
  fi;
  return f!.wbuf;
end );

# Read a full directory:
InstallGlobalFunction( IO_ListDir, function( dirname )
  local f,l,res;
  l := [];
  res := IO_opendir( dirname );
  if res = fail then
      return fail;
  fi;
  repeat
      f := IO_readdir();
      if IsString(f) then
          Add(l,f);
      fi;
  until f = false or f = fail;
  IO_closedir();
  return l;
end );

# A helper to make pairs IP address and port for TCP and UDP transfer:
InstallGlobalFunction( IO_MakeIPAddressPort, function(ip,port)
  local i,l,nr,res;
  l := SplitString(ip,".");
  if Length(l) <> 4 then
      Error("IPv4 adresses must have 4 numbers seperated by dots");
  fi;
  res := "    ";
  for i in [1..4] do
      nr := Int(l[i]);
      if nr < 0 or nr > 255 then
          Error("IPv4 addresses must contain numbers between 0 and 255");
      fi;
      res[i] := CHAR_INT(nr);
  od;
  if port < 0 or port > 65535 then
      Error("IPv4 port numbers must be between 0 and 65535");
  fi;
  return IO_make_sockaddr_in(res,port);
end );


#############################################################################
# Two helper functions to access and change the environment:                #
#############################################################################

InstallGlobalFunction( IO_Environment, function()
  # Returns a record with the components corresponding to the set
  # environment variables.
  local l,ll,p,r,v;
  l := IO_environ();
  r := rec();
  for v in l do
    p := Position(v,'=');
    if p <> fail then
      r.(v{[1..p-1]}) := v{[p+1..Length(v)]};
    fi;
  od;
  return r;
end );
  
InstallGlobalFunction( IO_MakeEnvList, function(r)
  # Returns a list of strings for usage with execve made from the 
  # components of r in the form "key=value".
  local k,l;
  l := [];
  for k in RecFields(r) do
    Add(l,Concatenation(k,"=",r.(k)));
  od;
  return l;
end );

IO.MaxFDToClose := 64;

InstallGlobalFunction( IO_CloseAllFDs, function(exceptions)
  local i;
  exceptions := Set(exceptions);
  for i in [0..IO.MaxFDToClose] do
    if not(i in exceptions) then
      IO_close(i);
    fi;
  od;
  return;
end );

InstallGlobalFunction( IO_Popen, function(path,argv,mode)
  # mode can be "w" or "r". In the first case, the standard input of the
  # new process will be a pipe, the writing end is returned as a File object.
  # In the second case, the standard output of the new process will be a
  # pipe, the reading end is returned as a File object.
  # The other (standard out or in resp.) is identical to the one of the
  # calling GAP process.
  # Returns fail if an error occurred.
  # The process will usually die, when the pipe is closed. It lies in the
  # responsability of the caller to WaitPid for it, if our SIGCHLD handler
  # has been activated.
  # The File object will have the Attribute "ProcessID" set to the process ID.
  local fil,pid,pipe;
  if not(IsExecutableFile(path)) then
      Error("Popen: <path> must refer to an executable file.");
  fi;
  if mode = "r" then
      pipe := IO_pipe(); if pipe = fail then return fail; fi;
      pid := IO_fork(); 
      if pid < 0 then 
        IO_close(pipe.toread);
        IO_close(pipe.towrite);
        return fail; 
      fi;
      if pid = 0 then   # the child
          # First close all files
          IO_CloseAllFDs([0,2,pipe.towrite]);
          IO_dup2(pipe.towrite,1);
          IO_close(pipe.towrite);
          IO_execv(path,argv);
          # The following should not happen:
          IO_exit(-1);
      fi;
      # Now the parent:
      IO_close(pipe.towrite);
      fil := IO_WrapFD(pipe.toread,IO.DefaultBufSize,false);
      SetProcessID(fil,pid);
      return fil;
  elif mode = "w" then
      pipe := IO_pipe(); if pipe = fail then return fail; fi;
      pid := IO_fork(); 
      if pid < 0 then 
        IO_close(pipe.toread);
        IO_close(pipe.towrite);
        return fail; 
      fi;
      if pid = 0 then   # the child
          # First close all files
          IO_CloseAllFDs([1,2,pipe.toread]);
          IO_dup2(pipe.toread,0);
          IO_close(pipe.toread);
          IO_execv(path,argv);
          # The following should not happen:
          IO_exit(-1);
      fi;
      # Now the parent:
      IO_close(pipe.toread);
      fil := IO_WrapFD(pipe.towrite,false,IO.DefaultBufSize);
      SetProcessID(fil,pid);
      return fil;
  else
      Error("mode must be \"r\" or \"w\".");
  fi;
end );

InstallGlobalFunction( IO_Popen2, function(path,argv)
  # A new child process is started. The standard in and out of it are
  # pipes. The writing end of the input pipe and the reading end of the
  # output pipe are returned as File objects bound to two components
  # "stdin" and "stdout" of the returned record. This means, you have to
  # *write* to "stdin" and read from "stdout". The stderr will be the same
  # as the one of the calling GAP process.
  # Returns fail if an error occurred.
  # The process will usually die, when one of the pipes is closed. It
  # lies in the responsability of the caller to WaitPid for it, if our
  # SIGCHLD handler has been activated.
  local pid,pipe,pipe2,stdin,stdout;
  if not(IsExecutableFile(path)) then
      Error("Popen: <path> must refer to an executable file.");
  fi;
  pipe := IO_pipe(); if pipe = fail then return fail; fi;
  pipe2 := IO_pipe(); 
  if pipe2 = fail then
    IO_close(pipe.toread);
    IO_close(pipe.towrite);
    return fail;
  fi;
  pid := IO_fork(); 
  if pid < 0 then 
    IO_close(pipe.toread);
    IO_close(pipe.towrite);
    IO_close(pipe2.toread);
    IO_close(pipe2.towrite);
    return fail; 
  fi;
  if pid = 0 then   # the child
      # First close all files
      IO_CloseAllFDs([2,pipe.toread,pipe2.towrite]);
      IO_dup2(pipe.toread,0);
      IO_close(pipe.toread);
      IO_dup2(pipe2.towrite,1);
      IO_close(pipe2.towrite);
      IO_execv(path,argv);
      # The following should not happen:
      IO_exit(-1);
  fi;
  # Now the parent:
  IO_close(pipe.toread);
  IO_close(pipe2.towrite);
  stdin := IO_WrapFD(pipe.towrite,false,IO.DefaultBufSize);
  stdout := IO_WrapFD(pipe2.toread,IO.DefaultBufSize,false);
  SetProcessID(stdin,pid);
  SetProcessID(stdout,pid);
  return rec(stdin := stdin, stdout := stdout, pid := pid);
end );

InstallGlobalFunction( IO_Popen3, function(path,argv)
  # A new child process is started. The standard in and out and error are
  # pipes. All three "other" ends of the pipes are returned as File
  # objectes bound to the three components "stdin", "stdout", and "stderr"
  # of the returned record. This means, you have to *write* to "stdin"
  # and read from "stdout" and "stderr".
  # Returns fail if an error occurred.
  local pid,pipe,pipe2,pipe3,stderr,stdin,stdout;
  if not(IsExecutableFile(path)) then
      Error("Popen: <path> must refer to an executable file.");
  fi;
  pipe := IO_pipe(); if pipe = fail then return fail; fi;
  pipe2 := IO_pipe(); 
  if pipe2 = fail then
    IO_close(pipe.toread);
    IO_close(pipe.towrite);
    return fail;
  fi;
  pipe3 := IO_pipe(); 
  if pipe3 = fail then
    IO_close(pipe.toread);
    IO_close(pipe.towrite);
    IO_close(pipe2.toread);
    IO_close(pipe2.towrite);
    return fail;
  fi;
  pid := IO_fork(); 
  if pid < 0 then 
    IO_close(pipe.toread);
    IO_close(pipe.towrite);
    IO_close(pipe2.toread);
    IO_close(pipe2.towrite);
    IO_close(pipe3.toread);
    IO_close(pipe3.towrite);
    return fail; 
  fi;
  if pid = 0 then   # the child
      # First close all files
      IO_CloseAllFDs([pipe.toread,pipe2.towrite,pipe3.towrite]);
      IO_dup2(pipe.toread,0);
      IO_close(pipe.toread);
      IO_dup2(pipe2.towrite,1);
      IO_close(pipe2.towrite);
      IO_dup2(pipe3.towrite,2);
      IO_close(pipe3.towrite);
      IO_execv(path,argv);
      # The following should not happen:
      IO_exit(-1);
  fi;
  # Now the parent:
  IO_close(pipe.toread);
  IO_close(pipe2.towrite);
  IO_close(pipe3.towrite);
  stdin := IO_WrapFD(pipe.towrite,false,IO.DefaultBufSize);
  stdout := IO_WrapFD(pipe2.toread,IO.DefaultBufSize,false);
  stderr := IO_WrapFD(pipe3.toread,IO.DefaultBufSize,false);
  SetProcessID(stdin,pid);
  SetProcessID(stdout,pid);
  SetProcessID(stderr,pid);
  return rec(stdin := stdin, stdout := stdout, stderr := stderr, pid := pid);
end );

InstallGlobalFunction( IO_SendStringBackground, function(f,st)
  # The whole string st is send to the File object f but in the background.
  # This works by forking off a child process which sends away the string
  # such that the parent can go on and can already read from the other end.
  # This is especially useful for piping large amounts of data through
  # a program that has been started with Popen2 or Popen3.
  # The component pid will be bound to the process id of the child process.
  # Returns fail if an error occurred.
  local pid,len;
  pid := IO_fork();
  if pid = -1 then
      return fail;
  fi;
  if pid = 0 then   # the child
      len := IO_Write(f,st);
      IO_Flush(f);
      IO_Close(f);
      IO_exit(0);
  fi;
  return true;
end );


#################
# (Un-)Pickling: 
#################

InstallValue( IO_Error,
  Objectify( NewType( IO_ResultsFamily, IO_Result ), rec( val := "IO_Error" ))
);
InstallValue( IO_Nothing,
  Objectify( NewType( IO_ResultsFamily, IO_Result ), rec( val := "IO_Nothing"))
);
InstallValue( IO_OK,
  Objectify( NewType( IO_ResultsFamily, IO_Result ), rec( val := "IO_OK"))
);
InstallMethod( \=, "for two IO_Results",
  [ IO_Result, IO_Result ],
  function(a,b) return a!.val = b!.val; end );
InstallMethod( \=, "for an IO_Result and another object",
  [ IO_Result, IsObject ], ReturnFalse );
InstallMethod( \=, "for another object and an IO_Result",
  [ IsObject, IO_Result], ReturnFalse );
InstallMethod( ViewObj, "for an IO_Result",
  [ IO_Result ],
  function(r) Print(r!.val); end );
 
InstallValue( IO_PICKLECACHE, rec( ids := [], nrs := [], obs := [],
                                   depth := 0 ) );

InstallGlobalFunction( IO_AddToPickled,
  function( ob )
    local id,pos;
    IO_PICKLECACHE.depth := IO_PICKLECACHE.depth + 1;
    id := IO_MasterPointerNumber(ob);
    pos := PositionSorted( IO_PICKLECACHE.ids, id );
    if pos <= Length(IO_PICKLECACHE.ids) and IO_PICKLECACHE.ids[pos] = id then
        return IO_PICKLECACHE.nrs[pos];
    else
        Add(IO_PICKLECACHE.ids,id,pos);
        Add(IO_PICKLECACHE.nrs,Length(IO_PICKLECACHE.ids),pos);
        return false;
    fi;
  end );

InstallGlobalFunction( IO_FinalizePickled,
  function( )
    IO_PICKLECACHE.depth := IO_PICKLECACHE.depth - 1;
    if IO_PICKLECACHE.depth = 0 then
        # important to clear the cache:
        IO_PICKLECACHE.ids := [];
        IO_PICKLECACHE.nrs := [];
    fi;
  end );

InstallGlobalFunction( IO_AddToUnpickled,
  function( ob )
    IO_PICKLECACHE.depth := IO_PICKLECACHE.depth + 1;
    Add( IO_PICKLECACHE.obs, ob );
  end );

InstallGlobalFunction( IO_FinalizeUnpickled,
  function( )
    IO_PICKLECACHE.depth := IO_PICKLECACHE.depth - 1;
    if IO_PICKLECACHE.depth = 0 then
        # important to clear the cache:
        IO_PICKLECACHE.obs := [];
    fi;
  end );

InstallGlobalFunction( IO_WriteSmallInt,
  function( f, i )
    local h,l;
    h := HexStringInt(i);
    l := Length(h);
    Add(h,CHAR_INT(Length(h)),1);
    if IO_Write(f,h) = fail then
        return IO_Error;
    else
        return IO_OK;
    fi;
  end ); 

InstallGlobalFunction( IO_ReadSmallInt,
  function( f )
    local h,l;
    l := IO_Read(f,1);
    if l = "" or l = fail then return IO_Error; fi;
    h := IO_Read(f,INT_CHAR(l[1]));
    if h = fail then return IO_Error; fi;
    return IntHexString(h);
  end );

InstallMethod( IO_Unpickle, "for a file",
  [ IsFile ],
  function( f )
    local magic,up;
    magic := IO_Read(f,4);
    if magic = fail then return IO_Error; 
    elif magic = "" then return IO_Nothing; 
    fi;
    if not(IsBound(IO_Unpicklers.(magic))) then
        Print("No unpickler for magic value \"",magic,"\"\n");
        return IO_Error;
    fi;
    up := IO_Unpicklers.(magic);
    if IsFunction(up) then
        return up(f);
    else
        return up;
    fi;
  end );

InstallValue( IO_Unpicklers, rec() );

InstallGlobalFunction( IO_PickleByString,
  function( f, ob, tag )
    local s;
    s := String(ob);
    if IO_Write(f,tag) = fail then return IO_Error; fi;
    if IO_WriteSmallInt(f,Length(s)) = IO_Error then return IO_Error; fi;
    if IO_Write(f,s) = fail then return IO_Error; fi;
    return IO_OK;
  end );
  
InstallGlobalFunction( IO_UnpickleByEvalString,
  function( f )
    local len,s;
    len := IO_ReadSmallInt(f);
    if len = IO_Error then return IO_Error; fi;
    s := IO_Read(f,len);
    if s = fail then return IO_Error; fi;
    return EvalString(s);
  end );
    
InstallMethod( IO_Pickle, "for an integer",
  [ IsFile, IsInt ],
  function( f, i )
    local h;
    if IO_Write( f, "INTG" ) = fail then return IO_Error; fi;
    h := HexStringInt(i);
    if IO_WriteSmallInt( f, Length(h) ) = fail then return IO_Error; fi;
    if IO_Write(f,h) = fail then return fail; fi;
    return IO_OK;
  end );

IO_Unpicklers.INTG :=
  function( f )
    local h,len;
    len := IO_ReadSmallInt(f);
    if len = IO_Error then return IO_Error; fi;
    h := IO_Read(f,len);
    if h = fail then return IO_Error; fi;
    return IntHexString(h);
  end;

InstallMethod( IO_Pickle, "for a string",
  [ IsFile, IsStringRep and IsList ],
  function( f, s )
    if IO_Write(f,"STRI") = fail then return IO_Error; fi;
    if IO_WriteSmallInt(f, Length(s)) = IO_Error then return IO_Error; fi;
    if IO_Write(f,s) = fail then return IO_Error; fi;
    return IO_OK;
  end );

IO_Unpicklers.STRI :=
  function( f )
    local len,s;
    len := IO_ReadSmallInt(f);
    if len = IO_Error then return IO_Error; fi;
    s := IO_Read(f,len);
    if s = fail then return IO_Error; fi;
    return s;
  end;

InstallMethod( IO_Pickle, "for a boolean",
  [ IsFile, IsBool ],
  function( f, b )
    local val;
    if b = false then val := "FALS";
    elif b = true then val := "TRUE";
    elif b = fail then val := "FAIL";
    elif b = SuPeRfail then val := "SPRF";
    else
        Error("Unknown boolean value");
    fi;
    if IO_Write(f,val) = fail then 
        return IO_Error;
    else
        return IO_OK;
    fi;
  end );

IO_Unpicklers.FALS := false;
IO_Unpicklers.TRUE := true;
IO_Unpicklers.FAIL := fail;
IO_Unpicklers.SPRF := SuPeRfail;

InstallMethod( IO_Pickle, "for a permutation",
  [ IsFile, IsPerm ],
  function( f, p )
    return IO_PickleByString( f, p, "PERM" );
  end );

IO_Unpicklers.PERM := IO_UnpickleByEvalString;

InstallMethod( IO_Pickle, "for a character",
  [ IsFile, IsChar ],
  function(f, c)
    local s;
    s := "CHARx";
    s[5] := c;
    if IO_Write(f,s) = fail then return IO_Error; fi;
    return IO_OK;
  end );

IO_Unpicklers.CHAR :=
  function( f )
    local s;
    s := IO_Read(f,1);
    return s[1];
  end;

InstallMethod( IO_Pickle, "for a finite field element",
  [ IsFile, IsFFE ], 
  function( f, ffe )
    return IO_PickleByString( f, ffe, "FFEL" );
  end );

IO_Unpicklers.FFEL := IO_UnpickleByEvalString;

InstallMethod( IO_Pickle, "for a cyclotomic",
  [ IsFile, IsCyclotomic ],
  function( f, cyc )
    return IO_PickleByString( f, cyc, "CYCL" );
  end );

IO_Unpicklers.CYCL := IO_UnpickleByEvalString;

InstallMethod( IO_Pickle, "for a list",
  [ IsFile, IsList ],
  function( f, l )
    local count,i,nr;
    nr := IO_AddToPickled(l);
    if nr = false then   # not yet known
        # Here we have to do something
        if IO_Write(f,"LIST") = fail then 
            IO_FinalizePickled();
            return IO_Error;
        fi;
        if IO_WriteSmallInt(f,Length(l)) = IO_Error then
            IO_FinalizePickled();
            return IO_Error;
        fi;
        count := 0;
        i := 1;
        while i <= Length(l) do
            if not(IsBound(l[i])) then
                count := count + 1;
            else
                if count > 0 then
                    if IO_Write(f,"GAPL") = fail then
                        IO_FinalizePickled();
                        return IO_Error;
                    fi;
                    if IO_WriteSmallInt(f,count) = IO_Error then
                        IO_FinalizePickled();
                        return IO_Error;
                    fi;
                    count := 0;
                fi;
                if IO_Pickle(f,l[i]) = IO_Error then
                    IO_FinalizePickled();
                    return IO_Error;
                fi;
            fi;
            i := i + 1;
        od;
        # Note that the last entry is always bound!
        IO_FinalizePickled();
        return IO_OK;
    else
        if IO_Write(f,"SREF") = IO_Error then 
            IO_FinalizePickled();
            return IO_Error;
        fi;
        if IO_WriteSmallInt(f,nr) = IO_Error then
            IO_FinalizePickled();
            return IO_Error;
        fi;
        IO_FinalizePickled();
        return IO_OK;
    fi;
  end );

IO_Unpicklers.LIST := 
  function( f )
    local i,j,l,len,ob;
    len := IO_ReadSmallInt(f);
    if len = IO_Error then return IO_Error; fi;
    l := 0*[1..len];
    IO_AddToUnpickled(l);
    i := 1;
    while i <= len do
        ob := IO_Unpickle(f);
        if ob = IO_Error then
            IO_FinalizeUnpickled();
            return IO_Error;
        fi;
        # IO_OK or IO_Nothing cannot happen!
        if IO_Result(ob) then
            if ob!.val = "Gap" then   # this is a Gap
                for j in [0..ob!.nr-1] do
                    Unbind(l[i+j]);
                od;
                i := i + ob!.nr;
            else    # this is a self-reference
                l[i] := IO_PICKLECACHE.obs[ob!.nr];
                i := i + 1;
            fi;
        else
            l[i] := ob;
            i := i + 1;
        fi;
    od;  # i is already incremented
    IO_FinalizeUnpickled();
    return l;
  end;

IO_Unpicklers.GAPL :=
  function( f )
    local ob;
    ob := rec( val := "Gap", nr := IO_ReadSmallInt(f) );
    if ob.nr = IO_Error then
        return IO_Error;
    fi;
    return Objectify( NewType( IO_ResultsFamily, IO_Result ), ob );
  end;

IO_Unpicklers.SREF := 
  function( f )
    local ob;
    ob := rec( val := "SRef", nr := IO_ReadSmallInt(f) );
    if ob.nr = IO_Error then
        return IO_Error;
    fi;
    return Objectify( NewType( IO_ResultsFamily, IO_Result ), ob );
  end;

InstallMethod( IO_Pickle, "for a record",
  [ IsFile, IsRecord ],
  function( f, r )
    local n,names,nr;
    nr := IO_AddToPickled(r);
    if nr = false then   # not yet known
        # Here we have to do something
        if IO_Write(f,"RECO") = fail then
            IO_FinalizePickled();
            return IO_Error;
        fi;
        names := RecNames(r);
        if IO_WriteSmallInt(f,Length(names)) = IO_Error then
            IO_FinalizePickled();
            return IO_Error;
        fi;
        for n in names do
            if IO_Pickle(f,n) = IO_Error then
                IO_FinalizePickled();
                return IO_Error;
            fi;
            if IO_Pickle(f,r.(n)) = IO_Error then
                IO_FinalizePickled();
                return IO_Error;
            fi;
        od;
        IO_FinalizePickled();
        return IO_OK;
    else
        if IO_Write(f,"SREF") = IO_Error then 
            IO_FinalizePickled();
            return IO_Error;
        fi;
        if IO_WriteSmallInt(f,nr) = IO_Error then
            IO_FinalizePickled();
            return IO_Error;
        fi;
        IO_FinalizePickled();
        return IO_OK;
    fi;
  end );

IO_Unpicklers.RECO := 
  function( f )
    local i,len,name,ob,r;
    len := IO_ReadSmallInt(f);
    if len = IO_Error then return IO_Error; fi;
    r := rec();
    IO_AddToUnpickled(r);
    for i in [1..len] do
        name := IO_Unpickle(f);
        if name = IO_Error or not(IsString(name)) then
            IO_FinalizeUnpickled();
            return IO_Error;
        fi;
        ob := IO_Unpickle(f);
        if IO_Result(ob) then
            if ob = IO_Error then
                IO_FinalizeUnpickled();
                return IO_Error;
            else   # this must be a self-reference
                r.(name) := IO_PICKLECACHE.obs[ob!.nr];
            fi;
        else
            r.(name) := ob;
        fi;
    od;
    IO_FinalizeUnpickled();
    return r;
  end;

InstallMethod( IO_Pickle, "IO_Results are forbidden",
  [ IsFile, IO_Result ],
  function( f, ob )
    Print("Pickling of IO_Result is forbidden!\n");
    return IO_Error;
  end );

InstallMethod( IO_Pickle, "for polynomials",
  [ IsFile, IsRationalFunction ],
  function( f, pol )
    local ext,one;
    one := One(CoefficientsFamily(FamilyObj(pol)));
    ext := ExtRepPolynomialRatFun(pol);
    if IO_Write(f,"POLY") = fail then return IO_Error; fi;
    if IO_Pickle(f,one) = IO_Error then return IO_Error; fi;
    if IO_Pickle(f,ext) = IO_Error then return IO_Error; fi;
    return IO_OK;
  end );

IO_Unpicklers.POLY :=
  function( f )
    local ext,one,poly;
    one := IO_Unpickle(f);
    if one = IO_Error then return IO_Error; fi;
    ext := IO_Unpickle(f);
    if ext = IO_Error then return IO_Error; fi;
    poly := PolynomialByExtRepNC( RationalFunctionsFamily(FamilyObj(one)),ext);
    return poly;
  end;

