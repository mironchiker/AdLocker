package com.adlocker.app.adlocker

import android.content.Intent
import android.net.VpnService
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import java.io.BufferedReader
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.InputStreamReader
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.nio.ByteBuffer
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import kotlin.concurrent.thread

class AdLockerVpnService : VpnService() {

    companion object {
        var isRunning = false
        var activeRulesCount = 0
        var queryListener: ((Map<String, Any>) -> Unit)? = null
    }

    private var vpnInterface: ParcelFileDescriptor? = null
    private var isWorkerRunning = false
    
    // ConcurrentHashMap с фиктивным значением для O(1) поиска без блокировок
    private val blackList = ConcurrentHashMap<String, Boolean>(150000)
    private val whiteList = ConcurrentHashMap<String, Boolean>(1000)
    
    private val mainHandler = Handler(Looper.getMainLooper())
    private val forwarderPool = Executors.newFixedThreadPool(8)

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "STOP") {
            stopVpn()
            return START_NOT_STICKY
        }
        loadRules()
        startVpn()
        return START_STICKY
    }

    private fun loadRules() {
        thread(name = "AdLocker-RulesLoader") {
            try {
                val candidateDirs = listOf(
                    File(filesDir, "app_flutter"),
                    filesDir,
                    noBackupFilesDir,
                    File(filesDir.parentFile, "app_flutter")
                )

                var rulesFile: File? = null
                for (dir in candidateDirs) {
                    val f = File(dir, "adblock_hosts_rules.txt")
                    if (f.exists() && f.length() > 0) {
                        rulesFile = f
                        break
                    }
                }

                if (rulesFile != null) {
                    blackList.clear()
                    BufferedReader(InputStreamReader(FileInputStream(rulesFile))).use { reader ->
                        var line = reader.readLine()
                        while (line != null) {
                            val trimmed = line.trim().lowercase()
                            if (trimmed.isNotEmpty() && !trimmed.startsWith("#")) {
                                blackList[trimmed] = true
                            }
                            line = reader.readLine()
                        }
                    }
                    activeRulesCount = blackList.size
                }

                var wlFile: File? = null
                for (dir in candidateDirs) {
                    val f = File(dir, "whitelist.txt")
                    if (f.exists() && f.length() > 0) {
                        wlFile = f
                        break
                    }
                }

                if (wlFile != null) {
                    whiteList.clear()
                    BufferedReader(InputStreamReader(FileInputStream(wlFile))).use { reader ->
                        var line = reader.readLine()
                        while (line != null) {
                            val trimmed = line.trim().lowercase()
                            if (trimmed.isNotEmpty()) {
                                whiteList[trimmed] = true
                            }
                            line = reader.readLine()
                        }
                    }
                }
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
    }

    private fun startVpn() {
        if (vpnInterface != null) return
        try {
            val builder = Builder()
            builder.setSession("AdLocker DNS")
            builder.setMtu(1500)
            
            builder.addAddress("10.254.1.2", 32)
            builder.addDnsServer("10.254.1.1")
            builder.addRoute("10.254.1.1", 32)

            builder.allowBypass()

            try {
                builder.addDisallowedApplication("com.google.android.apps.bard")
                builder.addDisallowedApplication("com.google.android.googlequicksearchbox")
            } catch (_: Exception) {}

            builder.setBlocking(true)
            vpnInterface = builder.establish()
            isRunning = true
            isWorkerRunning = true

            startDnsWorker()
        } catch (e: Exception) {
            e.printStackTrace()
            stopVpn()
        }
    }

    private fun startDnsWorker() {
        thread(name = "AdLocker-TunWorker") {
            val pfd = vpnInterface ?: return@thread
            val inStream = FileInputStream(pfd.fileDescriptor)
            val outStream = FileOutputStream(pfd.fileDescriptor)
            val packetBuffer = ByteArray(32767)

            val upstreamXbox = InetAddress.getByName("111.88.96.50")
            val fallbackAdguard = InetAddress.getByName("94.140.14.14")

            while (isWorkerRunning) {
                try {
                    val length = inStream.read(packetBuffer)
                    if (length <= 0) continue

                    if ((packetBuffer[0].toInt() shr 4) != 4) continue
                    if (packetBuffer[9].toInt() != 17) continue

                    val ihl = (packetBuffer[0].toInt() and 0x0F) * 4
                    val udpDstPort = ((packetBuffer[ihl + 2].toInt() and 0xFF) shl 8) or (packetBuffer[ihl + 3].toInt() and 0xFF)

                    if (udpDstPort == 53) {
                        val udpOffset = ihl + 8
                        val dnsLength = length - udpOffset
                        if (dnsLength < 12) continue

                        val dnsQuery = ByteArray(dnsLength)
                        System.arraycopy(packetBuffer, udpOffset, dnsQuery, 0, dnsLength)

                        val domain = parseDnsDomain(dnsQuery)
                        val isBlocked = shouldBlock(domain)

                        notifyFlutter(domain, isBlocked)

                        if (isBlocked) {
                            val dnsResponse = craftSinkholeDnsResponse(dnsQuery)
                            val fullPacket = craftUdpIpPacket(packetBuffer, ihl, dnsResponse)
                            synchronized(outStream) {
                                outStream.write(fullPacket)
                            }
                        } else {
                            val packetCopy = ByteArray(length)
                            System.arraycopy(packetBuffer, 0, packetCopy, 0, length)

                            forwarderPool.execute {
                                try {
                                    val socket = DatagramSocket()
                                    protect(socket)
                                    socket.soTimeout = 2000

                                    val outPacket = DatagramPacket(dnsQuery, dnsLength, upstreamXbox, 53)
                                    socket.send(outPacket)

                                    val inBuf = ByteArray(4096)
                                    val inPacket = DatagramPacket(inBuf, inBuf.size)
                                    var received = false

                                    try {
                                        socket.receive(inPacket)
                                        received = true
                                    } catch (_: Exception) {
                                        val fbPacket = DatagramPacket(dnsQuery, dnsLength, fallbackAdguard, 53)
                                        socket.send(fbPacket)
                                        socket.receive(inPacket)
                                        received = true
                                    }

                                    if (received) {
                                        val respBytes = ByteArray(inPacket.length)
                                        System.arraycopy(inBuf, 0, respBytes, 0, inPacket.length)
                                        val replyPacket = craftUdpIpPacket(packetCopy, ihl, respBytes)
                                        synchronized(outStream) {
                                            outStream.write(replyPacket)
                                        }
                                    }
                                    socket.close()
                                } catch (_: Exception) {}
                            }
                        }
                    }
                } catch (_: Exception) {}
            }
        }
    }

    private fun shouldBlock(domain: String): Boolean {
        if (domain.isEmpty()) return false
        val d = domain.trim().trimEnd('.').lowercase()

        if (whiteList.containsKey(d)) return false

        // 1. Точное попадание
        if (blackList.containsKey(d)) return true

        // 2. Иерархический поиск поддоменов: a.b.doubleclick.net -> b.doubleclick.net -> doubleclick.net
        var dotIndex = d.indexOf('.')
        while (dotIndex != -1) {
            val parent = d.substring(dotIndex + 1)
            if (blackList.containsKey(parent)) {
                return true
            }
            dotIndex = d.indexOf('.', dotIndex + 1)
        }

        return false
    }

    private fun parseDnsDomain(dns: ByteArray): String {
        var pos = 12
        val sb = StringBuilder()
        while (pos < dns.size) {
            val len = dns[pos].toInt() and 0xFF
            if (len == 0) break
            if ((len and 0xC0) == 0xC0) break
            pos++
            if (pos + len > dns.size) break
            if (sb.isNotEmpty()) sb.append(".")
            sb.append(String(dns, pos, len, Charsets.US_ASCII))
            pos += len
        }
        return sb.toString()
    }

    private fun craftSinkholeDnsResponse(query: ByteArray): ByteArray {
        val bb = ByteBuffer.allocate(query.size + 16)
        bb.put(query[0])
        bb.put(query[1])
        bb.put(0x81.toByte())
        bb.put(0x80.toByte())
        bb.putShort(1)
        bb.putShort(1)
        bb.putShort(0)
        bb.putShort(0)
        bb.put(query, 12, query.size - 12)
        bb.put(0xC0.toByte())
        bb.put(0x0C.toByte())
        bb.putShort(1)
        bb.putShort(1)
        bb.putInt(60)
        bb.putShort(4)
        bb.put(0.toByte())
        bb.put(0.toByte())
        bb.put(0.toByte())
        bb.put(0.toByte())

        val res = ByteArray(bb.position())
        System.arraycopy(bb.array(), 0, res, 0, res.size)
        return res
    }

    private fun craftUdpIpPacket(req: ByteArray, ihl: Int, payload: ByteArray): ByteArray {
        val totalLen = 20 + 8 + payload.size
        val out = ByteArray(totalLen)

        out[0] = 0x45.toByte()
        out[1] = 0
        out[2] = ((totalLen shr 8) and 0xFF).toByte()
        out[3] = (totalLen and 0xFF).toByte()
        out[4] = 0
        out[5] = 0
        out[6] = 0x40.toByte()
        out[7] = 0
        out[8] = 64
        out[9] = 17

        System.arraycopy(req, 16, out, 12, 4)
        System.arraycopy(req, 12, out, 16, 4)

        val ipChecksum = computeIpChecksum(out, 20)
        out[10] = ((ipChecksum shr 8) and 0xFF).toByte()
        out[11] = (ipChecksum and 0xFF).toByte()

        out[20] = req[ihl + 2]
        out[21] = req[ihl + 3]
        out[22] = req[ihl]
        out[23] = req[ihl + 1]
        val udpLen = 8 + payload.size
        out[24] = ((udpLen shr 8) and 0xFF).toByte()
        out[25] = (udpLen and 0xFF).toByte()
        out[26] = 0
        out[27] = 0

        System.arraycopy(payload, 0, out, 28, payload.size)
        return out
    }

    private fun computeIpChecksum(buf: ByteArray, length: Int): Int {
        var sum = 0
        var i = 0
        while (i < length) {
            if (i == 10) { i += 2; continue }
            val word = ((buf[i].toInt() and 0xFF) shl 8) or (buf[i + 1].toInt() and 0xFF)
            sum += word
            i += 2
        }
        while ((sum shr 16) > 0) {
            sum = (sum and 0xFFFF) + (sum shr 16)
        }
        return (sum.inv()) and 0xFFFF
    }

    private fun notifyFlutter(domain: String, isBlocked: Boolean) {
        mainHandler.post {
            val map = HashMap<String, Any>()
            map["domain"] = domain
            map["blocked"] = isBlocked
            map["time"] = System.currentTimeMillis()
            queryListener?.invoke(map)
        }
    }

    private fun stopVpn() {
        isWorkerRunning = false
        try {
            vpnInterface?.close()
            vpnInterface = null
            isRunning = false
            stopSelf()
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    override fun onDestroy() {
        stopVpn()
        super.onDestroy()
    }
}
