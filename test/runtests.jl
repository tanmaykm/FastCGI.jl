using FastCGI
using Test
using Random
using Sockets

function test_types()
    @testset "utility methods" begin
        @test FastCGI.BYTE(0x0102, 1) === 0x02
        @test FastCGI.BYTE(0x0102, 2) === 0x01
        @test FastCGI.B16(0x02, 0x03) === 0x0203
        @test FastCGI.padding(7) == 1
        @test FastCGI.padding(8) == 0
        @test FastCGI.padding(17) == 7
    end

    @testset "read-write nv lengths" begin
        p = PipeBuffer()
        @test FastCGI._writenvlen(p, UInt8(5)) == 1
        @test FastCGI._readnvlen(p) === UInt32(5)
        @test FastCGI._writenvlen(p, UInt16(127)) == 1
        @test FastCGI._readnvlen(p) === UInt32(127)
        @test FastCGI._writenvlen(p, UInt16(128)) == 4
        @test FastCGI._readnvlen(p) === UInt32(128)
        @test FastCGI._writenvlen(p, UInt16(1024)) == 4
        @test FastCGI._readnvlen(p) === UInt32(1024)
    end

    @testset "read-write types" begin
        p = PipeBuffer()
        reqid = UInt16(1)

        # FCGIBeginRequest
        req = FastCGI.FCGIBeginRequest(FastCGI.FCGIRequestRole.RESPONDER, FastCGI.KEEP_CONN)
        rec = FastCGI.FCGIRecord(FastCGI.FCGIHeaderType.BEGIN_REQUEST, reqid, req)
        @test FastCGI.fcgiwrite(p, rec) == 16
        @test FastCGI.FCGIRecord(p) == rec
        reqid += UInt16(1)

        # FCGIEndRequest
        req = FastCGI.FCGIEndRequest(UInt32(10), FastCGI.FCGIEndRequestProtocolStatus.REQUEST_COMPLETE)
        rec = FastCGI.FCGIRecord(FastCGI.FCGIHeaderType.END_REQUEST, reqid, req)
        @test FastCGI.fcgiwrite(p, rec) == 16
        @test FastCGI.FCGIRecord(p) == rec
        reqid += UInt16(1)

        # FCGIUnknownType
        req = FastCGI.FCGIUnknownType(UInt8(20))
        rec = FastCGI.FCGIRecord(FastCGI.FCGIHeaderType.END_REQUEST, reqid, req)
        @test FastCGI.fcgiwrite(p, rec) == 16
        @test FastCGI.FCGIRecord(p) == rec
        reqid += UInt16(1)

        # FCGIParams
        req = FastCGI.FCGIParams()
        push!(req.nvpairs, FastCGI.FCGINameValuePair("name1", "value1"))
        push!(req.nvpairs, FastCGI.FCGINameValuePair("name2", ""))
        push!(req.nvpairs, FastCGI.FCGINameValuePair("name1", randstring(512)))
        push!(req.nvpairs, FastCGI.FCGINameValuePair(randstring(512), randstring(1024)))
        rec = FastCGI.FCGIRecord(FastCGI.FCGIHeaderType.GET_VALUES, reqid, req)
        @test FastCGI.fcgiwrite(p, rec) == 2096
        @test FastCGI.FCGIRecord(p) == rec
        reqid += UInt16(1)
    end
end

function test_bufferedoutput()
    @testset "buffered output" begin
        out = IOBuffer()
        buffout = FastCGI.BufferedOutput((data)->write(out,data); delay=5.0, bytelimit=10)
        bytes = UInt8[1,2,3,4,5]
        write(buffout, bytes)
        sleep(1)
        @test position(out) == 0
        write(buffout, bytes)
        sleep(1)
        @test position(out) == 10
        write(buffout, bytes)
        sleep(1)
        @test position(out) == 10
        sleep(5)
        @test position(out) == 15
        write(buffout, bytes)
        flush(buffout)
        sleep(1)
        @test position(out) == 20
        close(buffout)
        @test !isopen(buffout.iob)
        sleep(6)
        @test istaskdone(buffout.waiter)
    end
end

function test_clientserver()
    @testset "client-server" begin
        @testset "Unix Domain Socket" begin
            testdir = dirname(@__FILE__)
            socket = joinpath(testdir, "fcgi.socket")
            cgiscript = joinpath(testdir, "hello.sh")

            # start server
            server = FCGIServer(socket)
            servertask = @async process(server)
            @test issocket(socket)
            @test isrunning(server)

            # run client
            client = FCGIClient(socket)
            headers = Dict("SCRIPT_FILENAME"=>cgiscript)

            # do multiple requests
            for idx in 1:10
                request = FCGIRequest(; headers=headers, keepconn=true)
                process(client, request)
                @test isrunning(client)
                wait(request.isdone)
                @test isempty(take!(request.err))
                response = take!(request.out)
                @test length(response) > 0
            end

            # close
            close(client)
            stop(server)
            @test !isrunning(client)
            @test !isrunning(server)
        end
        @testset "TCP Socket" begin
            testdir = dirname(@__FILE__)
            cgiscript = joinpath(testdir, "hello.sh")
            host = ip"127.0.0.1"
            port = 8989

            # start server
            server = FCGIServer(host, port)
            servertask = @async process(server)
            @test isa(server.lsock, Sockets.TCPServer)
            @test isrunning(server)

            # run client
            client = FCGIClient(host, port)
            headers = Dict("SCRIPT_FILENAME"=>cgiscript)

            # do multiple requests
            for idx in 1:10
                request = FCGIRequest(; headers=headers, keepconn=true)
                process(client, request)
                wait(request.isdone)
                @test isempty(take!(request.err))
                response = take!(request.out)
                @test length(response) > 0
            end

            # close
            close(client)
            stop(server)
            @test !isrunning(client)
            @test !isrunning(server)
        end
    end
end

test_bufferedoutput()
test_types()
test_clientserver()
