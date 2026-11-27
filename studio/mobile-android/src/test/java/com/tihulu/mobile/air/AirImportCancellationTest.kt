package com.tihulu.mobile.air

import org.junit.Test
import java.io.InputStream
import java.util.ArrayDeque
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class AirImportCancellationTest {
    @Test fun cancelledOrClosedBeforeWorkerSkipsAllKinds() {
        for(kind in AirImportLifecycle.Kind.entries) for(close in listOf(false,true)) {
            val worker=ArrayDeque<Runnable>(); val ui=ArrayDeque<()->Unit>()
            val runner=AirImportRunner(Executor{worker.addLast(it)},{ui.addLast(it);true})
            var executed=0; var released=0; var completed=0; var retired=0
            check(runner.start(kind,work={executed++;42},releaseInput={released++},retired={retired++}){completed++}==AirImportRunner.Start.STARTED)
            if(close) runner.close() else runner.cancel()
            check(runner.busy)
            worker.removeFirst().run(); check(runner.busy);ui.removeFirst().invoke()
            check(executed==0 && released==1 && completed==0 && retired==if(close)0 else 1)
            check(!runner.busy)
        }
    }

    @Test fun cancellationDuringReadStopsFurtherReadsAndClosesInput() {
        for(kind in listOf(AirImportLifecycle.Kind.ROOT,AirImportLifecycle.Kind.MODEL))
        for(single in listOf(false,true)) for(close in listOf(false,true)) {
            val worker=Executors.newSingleThreadExecutor()
            val mailbox=LinkedBlockingQueue<()->Unit>()
            val runner=AirImportRunner(worker,{mailbox.offer(it)})
            val entered=CountDownLatch(1); val release=CountDownLatch(1)
            val reads=AtomicInteger();val closes=AtomicInteger();var completed=0;var retired=0
            val input=object:InputStream(){
                override fun read():Int { reads.incrementAndGet(); entered.countDown(); check(release.await(5,TimeUnit.SECONDS)); return 42 }
                override fun read(b:ByteArray,off:Int,len:Int):Int { b[off]=read().toByte(); return 1 }
                override fun close(){closes.incrementAndGet()}
            }
            try {
                check(runner.start(kind,work={token->
                    input.use {
                        val checked=token.checkedInput(it)
                        repeat(2){if(single)checked.read() else checked.read(ByteArray(4))}
                    }
                },retired={retired++}){completed++}==AirImportRunner.Start.STARTED)
                check(entered.await(5,TimeUnit.SECONDS))
                if(close) runner.close() else runner.cancel()
                check(runner.busy && !runner.cancellable)
                check(runner.start(kind,work={error("must not start")}){}==AirImportRunner.Start.BUSY_OR_CLOSED)
                release.countDown(); val callback=mailbox.poll(5,TimeUnit.SECONDS) ?: error("no retirement")
                check(runner.busy && reads.get()==1 && closes.get()==1)
                callback()
                check(!runner.busy && completed==0 && retired==if(close)0 else 1)
            } finally {release.countDown();runner.close();worker.shutdown();check(worker.awaitTermination(5,TimeUnit.SECONDS))}
        }
    }

    @Test fun checkedInputPreservesOrdinaryReadsAndRejectsRetiredToken() {
        val gate=AirImportLifecycle();val token=gate.begin(AirImportLifecycle.Kind.MODEL)!!
        val data=byteArrayOf(0,1,2,3,4,5)
        val stream=token.checkedInput(data.inputStream());val buffer=ByteArray(5){-1}
        check(stream.read()==0);check(stream.read(buffer,1,3)==3)
        check(buffer.contentEquals(byteArrayOf(-1,1,2,3,-1)))
        check(stream.read(buffer)==2);check(buffer[0]==4.toByte() && buffer[1]==5.toByte())
        check(stream.read()==-1)
        check(gate.cancel()==AirImportLifecycle.Kind.MODEL)
        check(runCatching {stream.read()}.exceptionOrNull() is java.util.concurrent.CancellationException)
        check(gate.finish(token)==AirImportLifecycle.Completion.DISCARD)
        val next=gate.begin(AirImportLifecycle.Kind.ROOT)!!
        check(next.checkedInput(data.inputStream()).read()==0)
        check(runCatching {token.checkActive()}.exceptionOrNull() is java.util.concurrent.CancellationException)
        check(gate.finish(next)==AirImportLifecycle.Completion.ACCEPT)
    }
}
