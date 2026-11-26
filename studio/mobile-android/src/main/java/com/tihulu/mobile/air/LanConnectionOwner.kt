package com.tihulu.mobile.air

import java.io.Closeable
import java.io.IOException

/** Single-use connection ownership. Never execute socket I/O under the
 * monitor. Close the raw socket first to interrupt TLS reads/writes and
 * handshake, including a wrapper concurrently being constructed. */
internal class LanConnectionOwner:Closeable {
    private val lock=Any()
    private var started=false
    private var closed=false
    private var raw:Closeable?=null
    private var tls:Closeable?=null
    fun begin():Boolean=synchronized(lock){
        if(started||closed)false else {started=true;true}
    }
    fun installRaw(value:Closeable):Boolean=install(value,false)
    fun installTLS(value:Closeable):Boolean=install(value,true)
    private fun install(value:Closeable,wrapped:Boolean):Boolean {
        val accepted=synchronized(lock) {
            if(closed||!started||if(wrapped)raw==null||tls!=null else raw!=null)false
            else {
                if(wrapped)tls=value else raw=value
                true
            }
        }
        if(!accepted)quietClose(value)
        return accepted
    }
    fun requireOpen() {
        if(synchronized(lock){closed||!started})throw IOException("LAN connection retired")
    }
    override fun close() {
        val handles=synchronized(lock){
            if(closed)return
            closed=true
            val result=raw to tls
            raw=null;tls=null
            result
        }
        quietClose(handles.first)
        if(handles.second!==handles.first)quietClose(handles.second)
    }
    private fun quietClose(value:Closeable?) {
        try {value?.close()}catch(_:Exception){}
    }
}
