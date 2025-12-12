import Foundation
import CoreBluetooth
import Accelerate

let DeviceInformation = CBUUID(string:"180A")
let ManufacturerName = CBUUID(string:"2A29")
let ModelName = CBUUID(string:"2A24")
let ExposureNotification = CBUUID(string:"FD6F")

func getMACFromUUID(_ uuid: String) -> String? {
    guard let plist = NSDictionary(contentsOfFile: "/Library/Preferences/com.apple.Bluetooth.plist") else { return nil }
    guard let cbcache = plist["CoreBluetoothCache"] as? NSDictionary else { return nil }
    guard let device = cbcache[uuid] as? NSDictionary else { return nil }
    return device["DeviceAddress"] as? String
}

func getNameFromMAC(_ mac: String) -> String? {
    guard let plist = NSDictionary(contentsOfFile: "/Library/Preferences/com.apple.Bluetooth.plist") else { return nil }
    guard let devcache = plist["DeviceCache"] as? NSDictionary else { return nil }
    guard let device = devcache[mac] as? NSDictionary else { return nil }
    if let name = device["Name"] as? String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed == "" { return nil }
        return trimmed
    }
    return nil
}

class Device: NSObject, Codable {
    let uuid : UUID!
    var peripheral : CBPeripheral?
    var manufacture : String?
    var model : String?
    var advData: Data?
    var rssi: Int = 0
    var scanTimer: Timer?
    var macAddr: String?
    var blName: String?
    
    override var description: String {
        get {
            if macAddr == nil || blName == nil {
                if let info = getLEDeviceInfoFromUUID(uuid.description) {
                    blName = info.name
                    macAddr = info.macAddr
                }
            }
            if macAddr == nil {
                macAddr = getMACFromUUID(uuid.description)
            }
            if let mac = macAddr {
                if blName == nil {
                    blName = getNameFromMAC(mac)
                }
            }

            var modelName: String?
            if let manu = manufacture {
                if let mod = model {
                    if manu == "Apple Inc." && appleDeviceNames[mod] != nil {
                        modelName = appleDeviceNames[mod]!
                    } else {
                        modelName = String(format: "%@/%@", manu, mod)
                    }
                } else {
                    modelName = manu
                }
            } else if let mod = model {
                modelName = mod
            }

            if let name = blName {
                if let model = modelName {
                    if name.contains(model) {
                        return name
                    }
                    if model.contains(name) {
                        return model
                    }
                    return "\(name) - \(model)"
                }
                return name
            }

            if let model = modelName {
                return model
            }

            if let name = peripheral?.name {
                if name.trimmingCharacters(in: .whitespaces).count != 0 {
                    return name
                }
            }

            // iBeacon
            if let adv = advData {
                if adv.count >= 25 {
                    var iBeaconPrefix : [uint16] = [0x004c, 0x01502]
                    if adv[0...3] == Data(bytes: &iBeaconPrefix, count: 4) {
                        let major = uint16(adv[20]) << 8 | uint16(adv[21])
                        let minor = uint16(adv[22]) << 8 | uint16(adv[23])
                        let tx = Int8(bitPattern: adv[24])
                        let distance = pow(10, Double(Int(tx) - rssi)/20.0)
                        let d = String(format:"%.1f", distance)
                        return "iBeacon [\(major), \(minor)] \(d)m"
                    }
                }
            }
            if let mac = macAddr {
                return mac // better than uuid
            }
            return uuid.description
        }
    }

    init(uuid _uuid: UUID) {
        uuid = _uuid
    }

    enum CodingKeys: String, CodingKey {
        case uuid
        case manufacture
        case model
        case rssi
        case macAddr
        case blName
    }
}

protocol BLEDelegate {
    func newDevice(device: Device)
    func updateDevice(device: Device)
    func removeDevice(device: Device)
    func updateRSSI(uuid: UUID, rssi: Int?, active: Bool)
    func updatePresence(presence: Bool, reason: String)
    func bluetoothPowerWarn()
}

class BLE: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    let UNLOCK_DISABLED = 1
    let LOCK_DISABLED = -100
    var centralMgr : CBCentralManager!
    var devices : [UUID : Device] = [:]
    var delegate: BLEDelegate?
    var scanMode = false
    var monitoredUUIDs: [UUID] = []
    var removedUUIDs: [UUID] = []
    var monitoredPeripherals: [UUID: CBPeripheral] = [:]
    var proximityTimer : Timer?
    var signalTimers: [UUID: Timer] = [:]
    var presence = false
    var lockRSSI = -80
    var unlockRSSI = -60
    var proximityTimeout = 5.0
    var signalTimeout = 60.0
    var lastReadAt: [UUID: TimeInterval] = [:]
    var powerWarn = true
    var passiveMode = false
    var thresholdRSSI = -70
    var latestRSSIs: [UUID: [Double]] = [:]
    var latestN: Int = 5
    var activeModeTimer : Timer? = nil
    var connectionTimer: [UUID: Timer] = [:]

    func scanForPeripherals() {
        guard !centralMgr.isScanning else { return }
        centralMgr.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        //print("Start scanning")
    }

    func startScanning() {
        scanMode = true
        scanForPeripherals()
    }

    func stopScanning() {
        scanMode = false
        if activeModeTimer != nil {
            centralMgr.stopScan()
        }
    }

    func setPassiveMode(_ mode: Bool) {
        passiveMode = mode
        if passiveMode {
            activeModeTimer?.invalidate()
            activeModeTimer = nil
            for peripheral in monitoredPeripherals.values {
                centralMgr.cancelPeripheralConnection(peripheral)
            }
        }
        scanForPeripherals()
    }

    func startMonitor(uuids: [UUID]) {
        for peripheral in monitoredPeripherals.values {
            centralMgr.cancelPeripheralConnection(peripheral)
        }
        monitoredUUIDs = uuids
        for uuid in monitoredUUIDs {
            resetSignalTimer(uuid: uuid)
        }
        presence = true
        monitoredPeripherals.removeAll()
        activeModeTimer?.invalidate()
        activeModeTimer = nil
        scanForPeripherals()
    }

    func resetSignalTimer(uuid: UUID) {
        signalTimers[uuid]?.invalidate()
        signalTimers[uuid] = Timer.scheduledTimer(withTimeInterval: signalTimeout, repeats: false, block: { _ in
            print("Device is lost")
            self.latestRSSIs[uuid]?.removeAll()
            self.delegate?.updateRSSI(uuid: uuid, rssi: nil, active: false)
            self.updateOverallPresence()
        })
        if let timer = signalTimers[uuid] {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            print("Bluetooth powered on")
            if activeModeTimer == nil {
                scanForPeripherals()
            }
            powerWarn = false
        case .poweredOff:
            print("Bluetooth powered off")
            presence = false
            for timer in signalTimers.values {
                timer.invalidate()
            }
            signalTimers.removeAll()
            if powerWarn {
                powerWarn = false
                delegate?.bluetoothPowerWarn()
            }
        default:
            break
        }
    }
    
    func getEstimatedRSSI(uuid: UUID) -> Int {
        guard let rssis = latestRSSIs[uuid], !rssis.isEmpty else {
            return lockRSSI - 1
        }
        var mean: Double = 0.0
        var sddev: Double = 0.0
        vDSP_normalizeD(rssis, 1, nil, 1, &mean, &sddev, vDSP_Length(rssis.count))
        return Int(mean)
    }

    func getPresenceForUUID(uuid: UUID) -> Bool {
        let estimatedRSSI = getEstimatedRSSI(uuid: uuid)
        return estimatedRSSI >= (lockRSSI == LOCK_DISABLED ? unlockRSSI : lockRSSI)
    }

    func updateOverallPresence() {
        let anyDevicePresent = monitoredUUIDs.contains { getPresenceForUUID(uuid: $0) }
        let allDevicesAway = monitoredUUIDs.allSatisfy { !getPresenceForUUID(uuid: $0) }

        if anyDevicePresent {
            if !presence {
                print("At least one device is close")
                presence = true
                delegate?.updatePresence(presence: presence, reason: "close")
            }
            if let timer = proximityTimer {
                timer.invalidate()
                print("Proximity timer canceled")
                proximityTimer = nil
            }
        } else if allDevicesAway {
            if presence && proximityTimer == nil {
                proximityTimer = Timer.scheduledTimer(withTimeInterval: proximityTimeout, repeats: false, block: { _ in
                    print("All devices are away")
                    self.presence = false
                    self.delegate?.updatePresence(presence: self.presence, reason: "away")
                    self.proximityTimer = nil
                })
                RunLoop.main.add(proximityTimer!, forMode: .common)
                print("Proximity timer started")
            }
        }
    }

    func updateMonitoredPeripheral(uuid: UUID, rssi: Int) {
        if latestRSSIs[uuid] == nil {
            latestRSSIs[uuid] = []
        }
        if latestRSSIs[uuid]!.count >= latestN {
            latestRSSIs[uuid]!.removeFirst()
        }
        latestRSSIs[uuid]!.append(Double(rssi))

        let estimatedRSSI = getEstimatedRSSI(uuid: uuid)
        delegate?.updateRSSI(uuid: uuid, rssi: estimatedRSSI, active: activeModeTimer != nil)

        updateOverallPresence()

        resetSignalTimer(uuid: uuid)
    }

    func resetScanTimer(device: Device) {
        device.scanTimer?.invalidate()
        device.scanTimer = Timer.scheduledTimer(withTimeInterval: signalTimeout, repeats: false, block: { _ in
            self.delegate?.removeDevice(device: device)
            if let p = device.peripheral {
                self.centralMgr.cancelPeripheralConnection(p)
            }
            self.devices.removeValue(forKey: device.uuid)
        })
        if let timer = device.scanTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func connectMonitoredPeripheral(uuid: UUID) {
        guard let p = monitoredPeripherals[uuid] else { return }

        // Idk why but this works like a charm when 'didConnect' won't get called.
        // However, this generates warnings in the log.
        p.readRSSI()

        guard p.state == .disconnected else { return }
        print("Connecting")
        centralMgr.connect(p, options: nil)
        connectionTimer[uuid]?.invalidate()
        connectionTimer[uuid] = Timer.scheduledTimer(withTimeInterval: 60, repeats: false, block: { _ in
            if p.state == .connecting {
                print("Connection timeout")
                self.centralMgr.cancelPeripheralConnection(p)
            }
        })
        if let timer = connectionTimer[uuid] {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    //MARK:- CBCentralManagerDelegate start

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber)
    {
        let rssi = RSSI.intValue > 0 ? 0 : RSSI.intValue
        if monitoredUUIDs.contains(peripheral.identifier) {
            let uuid = peripheral.identifier
            if monitoredPeripherals[uuid] == nil {
                monitoredPeripherals[uuid] = peripheral
            }
            if activeModeTimer == nil {
                updateMonitoredPeripheral(uuid: uuid, rssi: rssi)
                if !passiveMode {
                    connectMonitoredPeripheral(uuid: uuid)
                }
            }
        }

        if (scanMode) {
            if removedUUIDs.contains(peripheral.identifier) {
                return
            }
            if let uuids = advertisementData["kCBAdvDataServiceUUIDs"] as? [CBUUID] {
                for uuid in uuids {
                    if uuid == ExposureNotification {
                        //print("Device \(peripheral.identifier) Exposure Notification")
                        return
                    }
                }
            }
            let dev = devices[peripheral.identifier]
            var device: Device
            if (dev == nil) {
                device = Device(uuid: peripheral.identifier)
                if (rssi >= thresholdRSSI) {
                    device.peripheral = peripheral
                    device.rssi = rssi
                    device.advData = advertisementData["kCBAdvDataManufacturerData"] as? Data
                    devices[peripheral.identifier] = device
                    central.connect(peripheral, options: nil)
                    delegate?.newDevice(device: device)
                }
            } else {
                device = dev!
                device.rssi = rssi
                delegate?.updateDevice(device: device)
            }
            resetScanTimer(device: device)
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didConnect peripheral: CBPeripheral)
    {
        peripheral.delegate = self
        if scanMode {
            peripheral.discoverServices([DeviceInformation])
        }
        if monitoredUUIDs.contains(peripheral.identifier) && !passiveMode {
            let uuid = peripheral.identifier
            print("Connected")
            connectionTimer[uuid]?.invalidate()
            connectionTimer.removeValue(forKey: uuid)
            peripheral.readRSSI()
        }
    }

    //MARK:CBCentralManagerDelegate end -
    
    //MARK:- CBPeripheralDelegate start

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard monitoredUUIDs.contains(peripheral.identifier) else { return }
        let uuid = peripheral.identifier
        let rssi = RSSI.intValue > 0 ? 0 : RSSI.intValue
        updateMonitoredPeripheral(uuid: uuid, rssi: rssi)
        lastReadAt[uuid] = Date().timeIntervalSince1970

        if activeModeTimer == nil && !passiveMode {
            print("Entering active mode")
            if !scanMode {
                centralMgr.stopScan()
            }
            activeModeTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true, block: { _ in
                for (u, p) in self.monitoredPeripherals {
                    if Date().timeIntervalSince1970 > (self.lastReadAt[u] ?? 0) + 10 {
                        print("Falling back to passive mode")
                        self.centralMgr.cancelPeripheralConnection(p)
                        self.activeModeTimer?.invalidate()
                        self.activeModeTimer = nil
                        self.scanForPeripherals()
                    } else if p.state == .connected {
                        p.readRSSI()
                    } else {
                        self.connectMonitoredPeripheral(uuid: u)
                    }
                }
            })
            RunLoop.main.add(activeModeTimer!, forMode: .common)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverServices error: Error?) {
        if let services = peripheral.services {
            for service in services {
                if service.uuid == DeviceInformation {
                    peripheral.discoverCharacteristics([ManufacturerName, ModelName], for: service)
                }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?)
    {
        if let chars = service.characteristics {
            for chara in chars {
                if chara.uuid == ManufacturerName || chara.uuid == ModelName {
                    peripheral.readValue(for:chara)
                }
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?)
    {
        if let value = characteristic.value {
            let str: String? = String(data: value, encoding: .utf8)
            if let s = str {
                if let device = devices[peripheral.identifier] {
                    if characteristic.uuid == ManufacturerName {
                        device.manufacture = s
                        delegate?.updateDevice(device: device)
                    }
                    if characteristic.uuid == ModelName {
                        device.model = s
                        delegate?.updateDevice(device: device)
                    }
                    if device.model != nil && device.manufacture != nil && !monitoredUUIDs.contains(device.uuid) {
                        centralMgr.cancelPeripheralConnection(peripheral)
                    }
                }
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral,
                    didModifyServices invalidatedServices: [CBService])
    {
        peripheral.discoverServices([DeviceInformation])
    }
    //MARK:CBPeripheralDelegate end -

    override init() {
        super.init()
        if let removed = UserDefaults.standard.stringArray(forKey: "removedDevices") {
            removedUUIDs = removed.compactMap { UUID(uuidString: $0) }
        }
        centralMgr = CBCentralManager(delegate: self, queue: nil)
    }
}
