package com.adlocker.app.adlocker

import android.content.Intent
import android.net.VpnService
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.nio.ByteBuffer
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
    private val blackList = HashSet<String>()
    private val whiteList = HashSet<String>()
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
        thread {
            try {
                val rulesFile = File(filesDir, "adblock_hosts_rules.txt")
                if (rulesFile.exists()) {
                    val lines = rulesFile.readLines()
                    synchronized(blackList) {
                        blackList.clear()
                        for (line in lines) {
                            val trimmed = line.trim().lowercase()
                            if (trimmed.isNotEmpty() && !trimmed.startsWith("#")) {
                                blackList.add(trimmed)
                            }
                        }
                        activeRulesCount = blackList.size
                    }
                }
                val wlFile = File(filesDir, "whitelist.txt")
                if (wlFile.exists()) {
                    val lines = wlFile.readLines()
                    synchronized(whiteList) {
                        whiteList.clear()
                        for (l in lines) {
                            val t = l.trim().lowercase()
                            if (t.isNotEmpty()) whiteList.add(t)
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
            
            // Назначаем виртуальный шлюз и перехватываем только DNS
            builder.addAddress("10.254.1.2", 32)
            builder.addDnsServer("10.254.1.1")
            builder.addRoute("10.254.1.1", 32)

            // Прямой доступ для остального трафика (сеть не падает)
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

                    // Валидация IPv4 (байт 0 = 0x45) и UDP (протокол 17)
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
                            // Локальный синтез ответа 0.0.0.0
                            val dnsResponse = craftSinkholeDnsResponse(dnsQuery)
                            val fullPacket = craftUdpIpPacket(packetBuffer, ihl, dnsResponse)
                            synchronized(outStream) {
                                outStream.write(fullPacket)
                            }
                        } else {
                            // Неблокирующий форвардинг в пуле потоков
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
                                        // Фоллбек на AdGuard при сбое основного upstream
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
        val d = domain.lowercase()
        synchronized(whiteList) {
            if (whiteList.contains(d)) return false
        }
        synchronized(blackList) {
            if (blackList.contains(d)) return true
            var dotIdx = d.indexOf('.')
            while (dotIdx != -1) {
                val parent = d.substring(dotIdx + 1)
                if (blackList.contains(parent)) return true
                dotIdx = d.indexOf('.', dotIdx + 1)
            }
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
        // Header
        bb.put(query[0]) // ID
        bb.put(query[1])
        bb.put(0x81.toByte()) // QR=1, RD=1
        bb.put(0x80.toByte()) // RA=1, RCODE=0 (NOERROR)
        bb.putShort(1) // QDCOUNT
        bb.putShort(1) // ANCOUNT
        bb.putShort(0) // NSCOUNT
        bb.putShort(0) // ARCOUNT
        
        // Question section
        bb.put(query, 12, query.size - 12)

        // Answer section: Name pointer to 0x0C
        bb.put(0xC0.toByte())
        bb.put(0x0C.toByte())
        bb.putShort(1) // TYPE A
        bb.putShort(1) // CLASS IN
        bb.putInt(60)  // TTL
        bb.putShort(4) // RDLENGTH 4
        bb.put(0.toByte()) // 0.0.0.0
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

        // IPv4 Header
        out[0] = 0x45.toByte()
        out[1] = 0
        out[2] = ((totalLen shr 8) and 0xFF).toByte()
        out[3] = (totalLen and 0xFF).toByte()
        out[4] = 0
        out[5] = 0
        out[6] = 0x40.toByte() // Don't Fragment
        out[7] = 0
        out[8] = 64 // TTL
        out[9] = 17 // UDP

        // Переворачиваем IP: Source <-> Dest
        System.arraycopy(req, 16, out, 12, 4)
        System.arraycopy(req, 12, out, 16, 4)

        // Чексумма заголовка IPv4 по RFC 1071 (ядро не отбросит пакет)
        val ipChecksum = computeIpChecksum(out, 20)
        out[10] = ((ipChecksum shr 8) and 0xFF).toByte()
        out[11] = (ipChecksum and 0xFF).toByte()

        // UDP Header
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

