# FastCGI.jl

[![Build Status](https://travis-ci.org/tanmaykm/FastCGI.jl.png)](https://travis-ci.org/tanmaykm/FastCGI.jl)

[![Coverage Status](https://coveralls.io/repos/github/tanmaykm/FastCGI.jl/badge.svg?branch=master)](https://coveralls.io/github/tanmaykm/FastCGI.jl?branch=master)

FastCGI is a binary protocol for interfacing interactive programs with a web server. It is a variation on the earlier Common Gateway Interface (CGI). FastCGI's main aim is to reduce the overhead related to interfacing between web server and CGI programs, allowing a server to handle more web page requests per unit of time.

FastCGI Specification: <http://www.mit.edu/~yandros/doc/specs/fcgi-spec.html>

FastCGI.jl is a package that implements a Julia FastCGI client and server.

## Examples:

### Using the server:
```
julia> using FastCGI

julia> server = FCGIServer("/var/run/fcgi/fcgi.socket")
FCGIServer(/var/run/fcgi/fcgi.socket, open)

julia> process(server)
┌ Info: processing
│   SCRIPT_FILENAME = "..."
└   SCRIPT_NAME = "..."
...
```

### Using the client:
```
julia> using FastCGI

julia> client = FCGIClient("/var/run/fcgi/fcgi.socket")
FCGIClient(/var/run/fcgi/fcgi.socket, open)

julia> headers = Dict("SCRIPT_FILENAME"=>"/fcgihome/hello.sh");

julia> request = FCGIRequest(; headers=headers)
FCGIRequest(complete=false, keepconn=false)

julia> process(client, request);

julia> wait(request.isdone)

julia> response = String(take!(request.out));
```
