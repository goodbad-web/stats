Created At: 2026-05-09T05:51:16Z
Completed At: 2026-05-09T05:51:16Z
File Path: `file:///Users/hiroshi/Desktop/MyStats/Modules/Sensors/readers.swift`
Total Lines: 876
Total Bytes: 36124
Showing lines 76 to 875
The following code has been modified to include a line number before every line, in the format: <line_number>: <original_line>. Please note that any changes targeting the original code should remove the line number, colon, and leading space.
76:     internal func includesHID(type: SensorType) -> Bool {
77:         self.isFull || self.hidTypes.contains(type.rawValue)
78:     }
79: 
80:     internal func includesIOPower(key: String) -> Bool {
81:         self.isFull || self.needsIOSensors || self.keys.contains(key)
82:     }
83: 
84:     internal func includesBattery(key: String) -> Bool {
85:         self.isFull || self.needsBattery || self.keys.contains(key)
86:     }
87: 
88:     private mutating func expandComputedDependencies(for key: String) {
89:         switch key {
90:         case "Average CPU", "Hottest CPU":
91:             self.types.insert(SensorType.temperature.rawValue)
92:             self.hidTypes.insert(SensorType.temperature.rawValue)
93:         case "Average GPU", "Hottest GPU":
94:             self.types.insert(SensorType.temperature.rawValue)
95:             self.hidTypes.insert(SensorType.temperature.rawValue)
96:         case "Average SOC", "Hottest SOC":
97:             self.hidTypes.insert(SensorType.temperature.rawValue)
98:         case "Average Fan", "Fastest fan":
99:             self.types.insert(SensorType.fan.rawValue)
100:             self.needsFanMode = true
101:         case "CPU Power", "GPU Power", "ANE Power", "RAM Power", "PCI Power":
102:             self.needsIOSensors = true
103:         case "battery_amperage", "battery_power":
104:             self.needsBattery = true
105:         case "Average System Total", "Total System Consumption":
106:             self.keys.insert("PSTR")
107:         default:
108:             break
109:         }
110:     }
111: 
112: }
113: 
114: private actor SensorsReaderWorker {
115:     private static let hidReadInterval: TimeInterval = 5
116:     private static let powerSensorReadInterval: TimeInterval = 5
117:     private static let throttledSMCKeys: Set<String> = ["PSTR"]
118: 
119:     private var lastRead: Date = Date()
120:     private var lastHIDRead: Date = .distantPast
121:     private var lastPowerSensorRead: Date = .distantPast
122:     private var lastBatteryRead: Date = .distantPast
123:     private let firstRead: Date = Date()
124:     private var lastIOSensorsRead: Date? = nil
125:     private var cachedBatteryData: (raw: Int, corrected: Int, voltage: Int)?
126:     
127:     private var channels: CFMutableDictionary?
128:     private var subscription: IOReportSubscriptionRef?
129:     private var powers: (CPU: Double, GPU: Double, ANE: Double, RAM: Double, PCI: Double, Media: Double) = (0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
130:     
131:     init() {
132:         let (c, s) = Self.initializeIOReport()
133:         self.channels = c
134:         self.subscription = s
135:     }
136:     
137:     static private func initializeIOReport() -> (CFMutableDictionary?, IOReportSubscriptionRef?) {
138:         let c = getChannels()
139:         var dict: Unmanaged<CFMutableDictionary>?
140:         let s = IOReportCreateSubscription(nil, c, &dict, 0, nil)
141:         dict?.release()
142:         return (c, s)
143:     }
144:     
145:     func read(scope: SensorsReadScope, unknownSensorsState: Bool, hidState: Bool, currentSensors: [Sensor_p]) async -> [Sensor_p] {
146:         var sensors = currentSensors
147:         let now = Date()
148:         let shouldReadPowerSensors = now.timeIntervalSince(self.lastPowerSensorRead) >= Self.powerSensorReadInterval
149:         let smcKeys = sensors.indices.compactMap { i -> String? in
150:             let s = sensors[i]
151:             if s.group != .hid && !s.isComputed && s.key != "battery_amperage" && s.key != "battery_power" {
152:                 if !unknownSensorsState && s.group == .unknown { return nil }
153:                 if !scope.contains(s) { return nil }
154:                 if Self.throttledSMCKeys.contains(s.key) && !shouldReadPowerSensors { return nil }
155:                 return s.key
156:             }
157:             return nil
158:         }
159:         let smcValues = await SMC.shared.getValues(smcKeys)
160:         if shouldReadPowerSensors && smcKeys.contains(where: { Self.throttledSMCKeys.contains($0) }) {
161:             self.lastPowerSensorRead = now
162:         }
163: 
164:         for i in sensors.indices {
165:             guard sensors[i].group != .hid && !sensors[i].isComputed else { continue }
166:             if !unknownSensorsState && sensors[i].group == .unknown { continue }
167:             guard scope.contains(sensors[i]) || scope.includesBattery(key: sensors[i].key) else { continue }
168: 
169:             var newValue: Double = sensors[i].value
170:             if sensors[i].key == "battery_amperage" || sensors[i].key == "battery_power" {
171:                 let batteryData = self.getCachedBatteryData(now: now)
172:                 if sensors[i].key == "battery_amperage" {
173:                     newValue = Double(abs(batteryData.corrected)) / 1000.0
174:                 } else if sensors[i].key == "battery_power" {
175:                     newValue = (Double(abs(batteryData.corrected)) / 1000.0) * (Double(batteryData.voltage) / 1000.0)
176:                 }
177:             } else if let value = smcValues[sensors[i].key] {
178:                 newValue = value
179:             } else if Self.throttledSMCKeys.contains(sensors[i].key) {
180:                 continue
181:             }
182: 
183:             if sensors[i].type == .temperature && (newValue < 0 || newValue > 125) {
184:                 newValue = sensors[i].value
185:             }
186:             sensors[i].value = newValue
187:         }
188: 
189:         var cpuSensors = sensors.filter({ $0.group == .CPU && $0.type == .temperature && $0.average }).map{ $0.value }
190:         var gpuSensors = sensors.filter({ $0.group == .GPU && $0.type == .temperature && $0.average }).map{ $0.value }
191:         let fanSensors = sensors.filter({ $0.type == .fan && !$0.isComputed })
192: 
193:         if hidState {
194:             if now.timeIntervalSince(self.lastHIDRead) >= Self.hidReadInterval {
195:                 var didReadHID = false
196:                 for typ in SensorsReader.HIDtypes {
197:                     guard scope.includesHID(type: typ) else { continue }
198:                     didReadHID = true
199:                     let (page, usage, type) = Self.m1Preset(type: typ)
200:                     AppleSiliconSensors(page, usage, type)?.forEach { (key, value) in
201:                         guard let key = key as? String, let value = value as? Double, value < 300 && value >= 0 else {
202:                             return
203:                         }
204: 
205:                         if let idx = sensors.firstIndex(where: { $0.group == .hid && $0.key == key }) {
206:                             sensors[idx].value = value
207:                         }
208:                     }
209:                 }
210:                 if didReadHID {
211:                     self.lastHIDRead = now
212:                 }
213:             }
214: 
215:             cpuSensors += sensors.filter({ $0.key.hasPrefix("pACC MTR Temp") || $0.key.hasPrefix("eACC MTR Temp") }).map{ $0.value }
216:             gpuSensors += sensors.filter({ $0.key.hasPrefix("GPU MTR Temp") }).map{ $0.value }
217: 
218:             let socSensors = sensors.filter({ $0.key.hasPrefix("SOC MTR Temp") }).map{ $0.value }
219:             if !socSensors.isEmpty {
220:                 if let idx = sensors.firstIndex(where: { $0.key == "Average SOC" }) {
221:                     sensors[idx].value = socSensors.reduce(0, +) / Double(socSensors.count)
222:                 }
223:                 if let idx = sensors.firstIndex(where: { $0.key == "Hottest SOC" }) {
224:                     sensors[idx].value = socSensors.max() ?? 0
225:                 }
226:             }
227:         }
228: 
229:         if !cpuSensors.isEmpty {
230:             if let idx = sensors.firstIndex(where: { $0.key == "Average CPU" }) {
231:                 sensors[idx].value = cpuSensors.reduce(0, +) / Double(cpuSensors.count)
232:             }
233:             if let idx = sensors.firstIndex(where: { $0.key == "Hottest CPU" }) {
234:                 sensors[idx].value = cpuSensors.max() ?? 0
235:             }
236:         }
237:         if !gpuSensors.isEmpty {
238:             if let idx = sensors.firstIndex(where: { $0.key == "Average GPU" }) {
239:                 sensors[idx].value = gpuSensors.reduce(0, +) / Double(gpuSensors.count)
240:             }
241:             if let idx = sensors.firstIndex(where: { $0.key == "Hottest GPU" }) {
242:                 sensors[idx].value = gpuSensors.max() ?? 0
243:             }
244:         }
245: 
246:         if !fanSensors.isEmpty {
247:             if let idx = sensors.firstIndex(where: { $0.key == "Average Fan" }) {
248:                 sensors[idx].value = fanSensors.map{ $0.value }.reduce(0, +) / Double(fanSensors.count)
249:             }
250:             if let idx = sensors.firstIndex(where: { $0.key == "Fastest fan" }) {
251:                 sensors[idx].value = fanSensors.map{ $0.value }.max() ?? 0
252:             }
253:         }
254: 
255:         if let PSTRSensor = sensors.first(where: { $0.key == "PSTR"}), PSTRSensor.value > 0 {
256:             let sinceLastRead = now.timeIntervalSince(self.lastRead)
257:             let sinceFirstRead = now.timeIntervalSince(self.firstRead)
258: 
259:             if let totalIdx = sensors.firstIndex(where: {$0.key == "Total System Consumption"}), sinceLastRead > 0 {
260:                 sensors[totalIdx].value += PSTRSensor.value * sinceLastRead / 3600
261:                 if let avgIdx = sensors.firstIndex(where: {$0.key == "Average System Total"}), sinceFirstRead > 0 {
262:                     sensors[avgIdx].value = sensors[totalIdx].value * 3600 / sinceFirstRead
263:                 }
264:             }
265:         }
266: 
267:         if let idx = sensors.firstIndex(where: { $0.key == "VD0R" }), sensors[idx].value < 0.4 {
268:             sensors[idx].value = 0
269:         }
270:         if let idx = sensors.firstIndex(where: { $0.key == "ID0R" }), sensors[idx].value < 0.05 {
271:             sensors[idx].value = 0
272:         }
273: 
274:         if scope.isFull || scope.needsIOSensors, let (cpu, gpu, ane, ram, pci, media) = self.IOSensors() {
275:             if let idx = sensors.firstIndex(where: { $0.key == "CPU Power" }) {
276:                 sensors[idx].value = cpu
277:             }
278:             if let idx = sensors.firstIndex(where: { $0.key == "GPU Power" }) {
279:                 sensors[idx].value = gpu
280:             }
281:             if let idx = sensors.firstIndex(where: { $0.key == "ANE Power" }) {
282:                 sensors[idx].value = ane
283:             }
284:             if let idx = sensors.firstIndex(where: { $0.key == "RAM Power" }) {
285:                 sensors[idx].value = ram
286:             }
287:             if let idx = sensors.firstIndex(where: { $0.key == "PCI Power" }) {
288:                 sensors[idx].value = pci
289:             }
290:             if let idx = sensors.firstIndex(where: { $0.key == "Media Power" }) {
291:                 sensors[idx].value = media
292:             }
293:         }
294:         
295:         self.lastRead = Date()
296:         return sensors
297:     }
298:     
299:     func setupInitialSensors(hidState: Bool) async -> [Sensor_p] {
300:         var available: [String] = await SMC.shared.getAllKeys()
301:         var list: [Sensor_p] = []
302:         var sensorsList = SensorsList
303: 
304:         if let platform = SystemKit.shared.device.platform {
305:             sensorsList = sensorsList.filter({ $0.platforms.contains(platform) })
306:         }
307: 
308:         if let count = await SMC.shared.getValue("FNum") {
309:             list += await self.loadFans(Int(count))
310:         }
311: 
312:         available = available.filter({ (key: String) -> Bool in
313:             switch key.prefix(1) {
314:             case "T", "V", "P", "I": return true
315:             default: return false
316:             }
317:         })
318: 
319:         sensorsList.forEach { (s: Sensor) in
320:             if let idx = available.firstIndex(where: { $0 == s.key }) {
321:                 list.append(s)
322:                 available.remove(at: idx)
323:             }
324:         }
325:         sensorsList.filter{ $0.key.contains("%") }.forEach { (s: Sensor) in
326:             var index = 1
327:             for i in 0..<10 {
328:                 let key = s.key.replacingOccurrences(of: "%", with: "\(i)")
329:                 if let idx = available.firstIndex(where: { $0 == key }) {
330:                     var sensor = s.copy()
331:                     sensor.key = key
332:                     sensor.name = s.name.replacingOccurrences(of: "%", with: "\(index)")
333: 
334:                     list.append(sensor)
335:                     available.remove(at: idx)
336:                     index += 1
337:                 }
338:             }
339:         }
340:         available.forEach { (key: String) in
341:             var type: SensorType? = nil
342:             switch key.prefix(1) {
343:             case "T": type = .temperature
344:             case "V": type = .voltage
345:             case "P": type = .power
346:             case "I": type = .current
347:             default: type = nil
348:             }
349:             if let t = type {
350:                 list.append(Sensor(key: key, name: key, group: .unknown, type: t, platforms: []))
351:             }
352:         }
353: 
354:         for i in list.indices {
355:             if let newValue = await SMC.shared.getValue(list[i].key) {
356:                 list[i].value = newValue
357:             }
358:         }
359: 
360:         var results: [Sensor_p] = []
361:         results += list.filter({ (s: Sensor_p) -> Bool in
362:             if s.type == .temperature && (s.value == 0 || s.value > 110) {
363:                 return false
364:             } else if s.type == .current && s.value > 100 {
365:                 return false
366:             }
367:             return true
368:         })
369: 
370:         if hidState {
371:             results += self.initHIDSensors()
372:         }
373:         results += self.initIOSensors()
374:         results += self.initCalculatedSensors(results, hidState: hidState)
375:         results.append(Sensor(key: "battery_amperage", name: "Battery", group: .sensor, type: .current, platforms: Platform.all))
376:         results.append(Sensor(key: "battery_power", name: "Battery", group: .sensor, type: .power, platforms: Platform.all))
377: 
378:         return results
379:     }
380:     
381:     func resetWorker() {
382:         self.subscription = nil
383:         self.channels = nil
384:     }
385:     
386:     func isAC() -> Bool {
387:         guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
388:               let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
389:             return true
390:         }
391: 
392:         for source in sources {
393:             if let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] {
394:                 if let type = description[kIOPSTypeKey] as? String, type == kIOPSInternalBatteryType {
395:                     if let powerSource = description[kIOPSPowerSourceStateKey] as? String {
396:                         return powerSource == kIOPSACPowerValue
397:                     }
398:                 }
399:             }
400:         }
401: 
402:         return true
403:     }
404:     
405:     func getHIDSensors() -> [Sensor] {
406:         return self.initHIDSensors()
407:     }
408: 
409:     private func getCachedBatteryData(now: Date) -> (raw: Int, corrected: Int, voltage: Int) {
410:         if let cachedBatteryData = self.cachedBatteryData,
411:            now.timeIntervalSince(self.lastBatteryRead) < Self.powerSensorReadInterval {
412:             return cachedBatteryData
413:         }
414: 
415:         let data = self.getBatteryData()
416:         self.cachedBatteryData = data
417:         self.lastBatteryRead = now
418:         return data
419:     }
420: 
421:     private func getBatteryData() -> (raw: Int, corrected: Int, voltage: Int) {
422:         var raw: Int = 0
423:         var corrected: Int = 0
424:         var voltage: Int = 0
425: 
426:         let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
427:         if service != 0 {
428:             if let amperage = IORegistryEntryCreateCFProperty(service, "Amperage" as CFString, kCFAllocatorDefault, 0) {
429:                 raw = (amperage.takeRetainedValue() as? Int ?? 0)
430:             } else if let amperage = IORegistryEntryCreateCFProperty(service, "InstantAmperage" as CFString, kCFAllocatorDefault, 0) {
431:                 raw = (amperage.takeRetainedValue() as? Int ?? 0)
432:             }
433: 
434:             if let v = IORegistryEntryCreateCFProperty(service, "Voltage" as CFString, kCFAllocatorDefault, 0) {
435:                 voltage = (v.takeRetainedValue() as? Int ?? 0)
436:             }
437: 
438:             corrected = raw
439:             if let telemetry = IORegistryEntryCreateCFProperty(service, "PowerTelemetryData" as CFString, kCFAllocatorDefault, 0) {
440:                 if let dict = telemetry.takeRetainedValue() as? [String: Any] {
441:                     let batteryPowerMW = dict["BatteryPower"] as? Int ?? (dict["BatteryPower"] as? Double).map{ Int($0) }
442:                     if let power = batteryPowerMW, power == 0 && abs(raw) < 50 {
443:                         corrected = 0
444:                     }
445:                 }
446:             }
447:             IOObjectRelease(service)
448:         }
449:         return (raw, corrected, voltage)
450:     }
451:     
452:     private func loadFans(_ count: Int) async -> [Sensor_p] {
453:         var list: [Fan] = []
454:         for i in 0..<Int(count) {
455:             var name = await SMC.shared.getStringValue("F\(i)ID")
456: 
457:             if name == nil && count == 2 {
458:                 switch i {
459:                 case 0:
460:                     name = localizedString("Left fan")
461:                 case 1:
462:                     name = localizedString("Right fan")
463:                 default: break
464:                 }
465:             }
466: 
467:             let modeValue = Int(await SMC.shared.getValue(await SMC.shared.fanModeKey(i)) ?? 0)
468:             let mode: FanMode = modeValue == 1 ? .forced : .automatic
469: 
470:             list.append(Fan(
471:                 id: i,
472:                 key: "F\(i)Ac",
473:                 name: name ?? "\(localizedString("Fan")) #\(i)",
474:                 minSpeed: await SMC.shared.getValue("F\(i)Mn") ?? 1,
475:                 maxSpeed: await SMC.shared.getValue("F\(i)Mx") ?? 1,
476:                 value: await SMC.shared.getValue("F\(i)Ac") ?? 0,
477:                 mode: mode
478:             ))
479:         }
480: 
481:         return list
482:     }
483:     
484:     private func initHIDSensors() -> [Sensor] {
485:         var list: [Sensor] = []
486: 
487:         for typ in SensorsReader.HIDtypes {
488:             let (page, usage, type) = Self.m1Preset(type: typ)
489:             if let sensors = AppleSiliconSensors(page, usage, type) {
490:                 sensors.forEach { (key, value) in
491:                     guard let key = key as? String, let value = value as? Double else {
492:                         return
493:                     }
494:                     var name: String = key
495: 
496:                     HIDSensorsList.forEach { (s: Sensor) in
497:                         if s.key.contains("%") {
498:                             var index = 1
499:                             for i in 0..<64 {
500:                                 if s.key.replacingOccurrences(of: "%", with: "\(i)") == key {
501:                                     name = s.name.replacingOccurrences(of: "%", with: "\(index)")
502:                                 }
503:                                 index += 1
504:                             }
505:                         } else if s.key == key {
506:                             name = s.name
507:                         }
508:                     }
509: 
510:                     list.append(Sensor(
511:                         key: key,
512:                         name: name,
513:                         value: value,
514:                         group: .hid,
515:                         type: typ,
516:                         platforms: Platform.all
517:                     ))
518:                 }
519:             }
520:         }
521: 
522:         let socSensors = list.filter({ $0.key.hasPrefix("SOC MTR Temp") }).map{ $0.value }
523:         if !socSensors.isEmpty {
524:             let value = socSensors.reduce(0, +) / Double(socSensors.count)
525:             list.append(Sensor(key: "Average SOC", name: "Average SOC", value: value, group: .hid, type: .temperature, platforms: Platform.all))
526:             if let max = socSensors.max() {
527:                 list.append(Sensor(key: "Hottest SOC", name: "Hottest SOC", value: max, group: .hid, type: .temperature, platforms: Platform.all))
528:             }
529:         }
530: 
531:         return list.filter({ (s: Sensor_p) -> Bool in
532:             switch s.type {
533:             case .temperature:
534:                 return s.value < 110 && s.value >= 0
535:             case .voltage:
536:                 return s.value < 300 && s.value >= 0
537:             case .current:
538:                 return s.value < 100 && s.value >= 0
539:             default: return true
540:             }
541:         }).sorted { $0.key.lowercased() < $1.key.lowercased() }
542:     }
543:     
544:     private func initIOSensors() -> [Sensor] {
545:         guard let (cpu, gpu, ane, ram, pci, media) = self.IOSensors() else { return [] }
546:         return [
547:             Sensor(key: "CPU Power", name: "CPU Power", value: cpu, group: .CPU, type: .power, platforms: Platform.apple, isComputed: true),
548:             Sensor(key: "GPU Power", name: "GPU Power", value: gpu, group: .GPU, type: .power, platforms: Platform.apple, isComputed: true),
549:             Sensor(key: "ANE Power", name: "ANE Power", value: ane, group: .system, type: .power, platforms: Platform.apple, isComputed: true),
550:             Sensor(key: "RAM Power", name: "RAM Power", value: ram, group: .system, type: .power, platforms: Platform.apple, isComputed: true),
551:             Sensor(key: "PCI Power", name: "PCI Power", value: pci, group: .system, type: .power, platforms: Platform.apple, isComputed: true),
552:             Sensor(key: "Media Power", name: "Media Power", value: media, group: .system, type: .power, platforms: Platform.apple, isComputed: true)
553:         ]
554:     }
555:     
556:     private func initCalculatedSensors(_ sensors: [Sensor_p], hidState: Bool) -> [Sensor_p] {
557:         var list: [Sensor_p] = []
558: 
559:         var cpuSensors = sensors.filter({ $0.group == .CPU && $0.type == .temperature && $0.average }).map{ $0.value }
560:         var gpuSensors = sensors.filter({ $0.group == .GPU && $0.type == .temperature && $0.average }).map{ $0.value }
561: 
562:         if hidState {
563:             cpuSensors += sensors.filter({ $0.key.hasPrefix("pACC MTR Temp") || $0.key.hasPrefix("eACC MTR Temp") }).map{ $0.value }
564:             gpuSensors += sensors.filter({ $0.key.hasPrefix("GPU MTR Temp") }).map{ $0.value }
565:         }
566: 
567:         let fanSensors = sensors.filter({ $0.type == .fan && !$0.isComputed })
568: 
569:         if !cpuSensors.isEmpty {
570:             let value = cpuSensors.reduce(0, +) / Double(cpuSensors.count)
571:             list.append(Sensor(key: "Average CPU", name: "Average CPU", value: value, group: .CPU, type: .temperature, platforms: Platform.all, isComputed: true))
572:             if let max = cpuSensors.max() {
573:                 list.append(Sensor(key: "Hottest CPU", name: "Hottest CPU", value: max, group: .CPU, type: .temperature, platforms: Platform.all, isComputed: true))
574:             }
575:         }
576:         if !gpuSensors.isEmpty {
577:             let value = gpuSensors.reduce(0, +) / Double(gpuSensors.count)
578:             list.append(Sensor(key: "Average GPU", name: "Average GPU", value: value, group: .GPU, type: .temperature, platforms: Platform.all, isComputed: true))
579:             if let max = gpuSensors.max() {
580:                 list.append(Sensor(key: "Hottest GPU", name: "Hottest GPU", value: max, group: .GPU, type: .temperature, platforms: Platform.all, isComputed: true))
581:             }
582:         }
583:         if !fanSensors.isEmpty && fanSensors.count > 1 {
584:             if let f = fanSensors.max(by: { $0.value < $1.value }) as? Fan {
585:                 list.append(Fan(id: -1, key: "Fastest fan", name: "Fastest fan", minSpeed: f.minSpeed, maxSpeed: f.maxSpeed, value: f.value, mode: .automatic, isComputed: true))
586:             }
587:         }
588: 
589:         if sensors.contains(where: { $0.key == "PSTR"}) {
590:             list.append(Sensor(key: "Total System Consumption", name: "Total System Consumption", value: 0, group: .sensor, type: .energy, platforms: Platform.all, isComputed: true))
591:             list.append(Sensor(key: "Average System Total", name: "Average System Total", value: 0, group: .sensor, type: .power, platforms: Platform.all, isComputed: true))
592:         }
593: 
594:         return list.filter({ (s: Sensor_p) -> Bool in
595:             switch s.type {
596:             case .temperature:
597:                 return s.value < 110 && s.value >= 0
598:             case .voltage:
599:                 return s.value < 300 && s.value >= 0
600:             case .current:
601:                 return s.value < 100 && s.value >= 0
602:             default: return true
603:             }
604:         }).sorted { $0.key.lowercased() < $1.key.lowercased() }
605:     }
606:     
607:     static private func getChannels() -> CFMutableDictionary? {
608:         guard let channels = IOReportCopyChannelsInGroup("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue() else {
609:             return nil
610:         }
611:         
612:         let size = CFDictionaryGetCount(channels)
613:         guard let dict = channels as? [String: Any],
614:               let items = dict["IOReportChannels"] as? [[String: Any]] else {
615:             return nil
616:         }
617:         
618:         var filteredItems: [[String: Any]] = []
619:         for item in items {
620:             if let name = item["IOReportChannelName"] as? String {
621:                 if name.hasSuffix("CPU Energy") || name.hasSuffix("GPU Energy") || 
622:                    name.hasPrefix("ANE") || name.hasPrefix("DRAM") || 
623:                    (name.hasPrefix("PCI") && name.hasSuffix("Energy")) || 
624:                    name.hasSuffix("Media Energy") || name.hasPrefix("VCP") || name.hasPrefix("DCP") {
625:                     filteredItems.append(item)
626:                 }
627:             }
628:         }
629:         
630:         if filteredItems.isEmpty { return nil }
631:         
632:         var mutableDict = dict
633:         mutableDict["IOReportChannels"] = filteredItems
634:         return CFDictionaryCreateMutableCopy(kCFAllocatorDefault, size, mutableDict as CFDictionary)
635:     }
636:     private func IOSensors() -> (Double, Double, Double, Double, Double, Double)? {
637:         guard let reportSample = IOReportCreateSamples(self.subscription, self.channels, nil)?.takeRetainedValue(),
638:                let dict = (reportSample as AnyObject) as? [String: Any] else {
639:             return nil
640:         }
641:         guard let items = dict["IOReportChannels"] as? NSArray else {
642:             return nil
643:         }
644:         let now = Date()
645: 
646:         let prevCPU = self.powers.CPU
647:         let prevGPU = self.powers.GPU
648:         let prevANE = self.powers.ANE
649:         let prevRAM = self.powers.RAM
650:         let prevPCI = self.powers.PCI
651:         let prevMedia = self.powers.Media
652: 
653:         for i in 0..<items.count {
654:             guard let item = items[i] as? NSDictionary else { continue }
655:             let channelInfo = item as CFDictionary
656: 
657:             guard let group = IOReportChannelGetGroup(channelInfo)?.takeUnretainedValue() as? String,
660:                   group == "Energy Model",
661:                   let channel = IOReportChannelGetChannelName(channelInfo)?.takeUnretainedValue() as? String,
662:                   let unit = IOReportChannelGetUnitLabel(channelInfo)?.takeUnretainedValue() as? String else { continue }
663: 
664:             let value = Double(IOReportSimpleGetIntegerValue(channelInfo, 0))
665: 
666:             if channel.hasSuffix("CPU Energy") {
667:                 self.powers.CPU = value.power(unit)
668:             } else if channel.hasSuffix("GPU Energy") {
669:                 self.powers.GPU = value.power(unit)
670:             } else if channel.starts(with: "ANE") {
671:                 self.powers.ANE = value.power(unit)
672:             } else if channel.starts(with: "DRAM") {
673:                 self.powers.RAM = value.power(unit)
674:             } else if channel.starts(with: "PCI") && channel.hasSuffix("Energy") {
675:                 self.powers.PCI = value.power(unit)
676:             } else if channel.hasSuffix("Media Energy") || channel.starts(with: "VCP") || channel.starts(with: "DCP") {
677:                 self.powers.Media = value.power(unit)
678:             }
679:         }
680: 
681:         guard let lastIOSensorsRead = self.lastIOSensorsRead else {
682:             self.lastIOSensorsRead = now
683:             return (0, 0, 0, 0, 0, 0)
684:         }
685:         guard prevCPU != 0 else {
686:             self.lastIOSensorsRead = now
687:             return (0, 0, 0, 0, 0, 0)
688:         }
689: 
690:         let elapsed = now.timeIntervalSince(lastIOSensorsRead)
691:         defer { self.lastIOSensorsRead = now }
692:         return (
693:             (self.powers.CPU - prevCPU) / elapsed,
694:             (self.powers.GPU - prevGPU) / elapsed,
695:             (self.powers.ANE - prevANE) / elapsed,
696:             (self.powers.RAM - prevRAM) / elapsed,
697:             (self.powers.PCI - prevPCI) / elapsed,
698:             (self.powers.Media - prevMedia) / elapsed
699:         )
700:     }
701:     
702:     static private func m1Preset(type: SensorType) -> (Int32, Int32, Int32) {
703:         var page: Int32 = 0
704:         var usage: Int32 = 0
705:         var eventType: Int32 = kIOHIDEventTypeTemperature
706: 
707:         switch type {
708:         case .temperature:
709:             page = 0xff00
710:             usage = 0x0005
711:             eventType = kIOHIDEventTypeTemperature
712:         case .current:
713:             page = 0xff08
714:             usage = 0x0002
715:             eventType = kIOHIDEventTypePower
716:         case .voltage:
717:             page = 0xff08
718:             usage = 0x0003
719:             eventType = kIOHIDEventTypePower
720:         case .power, .energy, .fan: break
721:         }
722: 
723:         return (page, usage, eventType)
724:     }
725: }
726: 
727: internal class SensorsReader: Reader<Sensors_List>, @unchecked Sendable {
728:     nonisolated static let HIDtypes: [SensorType] = [.temperature, .voltage]
729: 
730:     internal enum ActivityMode {
731:         case active
732:         case passive
733:         case paused
734:     }
735: 
736:     nonisolated private let listLock = OSAllocatedUnfairLock(initialState: Sensors_List())
737:     nonisolated internal var list: Sensors_List {
738:         get { self.listLock.withLock { $0 } }
739:         set { self.listLock.withLock { $0 = newValue } }
740:     }
741:     private let worker = SensorsReaderWorker()
742: 
743:     private nonisolated var hidState: Bool {
744:         Store.shared.bool(key: "Sensors_hid", defaultValue: true)
745:     }
746:     private var userInterval: Int = Store.shared.int(key: "Sensors_updateInterval", defaultValue: 5)
747:     private var activityMode: ActivityMode = .active
748:     private var effectiveInterval: Int?
749:     nonisolated private let unknownSensorsStateLock = OSAllocatedUnfairLock(initialState: false)
750:     nonisolated private let readScopeLock = OSAllocatedUnfairLock(initialState: SensorsReadScope.full)
751: 
752:     @MainActor init(callback: @escaping (T?) -> Void = {_ in }) {
753:         self.unknownSensorsStateLock.withLock { $0 = Store.shared.bool(key: "Sensors_unknown", defaultValue: false) }
754:         super.init(.sensors, callback: callback)
755: 
756:         let worker = self.worker
757:         let hidState = self.hidState
758:         Task {
759:             let list = await worker.setupInitialSensors(hidState: hidState)
760:             await MainActor.run {
761:                 self.list.sensors = list
762:                 self.callback(self.list)
763:             }
764:         }
765:     }
766: 
767:     internal func setUserInterval(_ value: Int) {
768:         guard self.userInterval != value else { return }
769:         self.userInterval = value
770:         self.applyActivityMode()
771:     }
772: 
773:     internal func setActivityMode(_ mode: ActivityMode) {
774:         guard self.activityMode != mode else { return }
775:         self.activityMode = mode
776:         self.applyActivityMode()
777:     }
778: 
779:     internal func setReadScope(_ scope: SensorsReadScope) {
780:         self.readScopeLock.withLock {
781:             guard $0 != scope else { return }
782:             $0 = scope
783:         }
784:     }
785: 
786:     private func applyActivityMode() {
787:         switch self.activityMode {
788:         case .active:
789:             self.applyInterval(self.userInterval)
790:             self.sleepMode(state: false)
791:         case .passive:
792:             self.applyInterval(max(self.userInterval * 5, 30))
793:             self.sleepMode(state: false)
794:         case .paused:
795:             self.sleepMode(state: true)
796:         }
797:     }
798: 
799:     private func applyInterval(_ value: Int) {
800:         guard self.effectiveInterval != value else { return }
801:         self.effectiveInterval = value
802:         super.setInterval(value)
803:     }
804: 
805:     public override func readAsync() async -> Sensors_List? {
806:         let scope = self.readScopeLock.withLock { $0 }
807:         let unknownState = self.unknownSensorsStateLock.withLock { $0 }
808:         let currentSensors = self.list.sensors
809:         
810:         let updatedSensors = await self.worker.read(
811:             scope: scope, 
812:             unknownSensorsState: unknownState, 
813:             hidState: self.hidState, 
814:             currentSensors: currentSensors
815:         )
816:         
817:         let safetyState = Store.shared.bool(key: "Sensors_fanSafety", defaultValue: true)
818:         if safetyState {
819:             let hottest = updatedSensors.filter{ $0.type == .temperature && ($0.group == .CPU || $0.group == .GPU || $0.group == .hid) }.map{ $0.value }.max() ?? 0
820:             if hottest > 95 {
821:                 if updatedSensors.compactMap({ $0 as? Fan }).contains(where: { $0.mode == .forced }) {
822:                     await SMCHelper.shared.resetFanControl()
823:                     await MainActor.run {
824:                         NotificationCenter.default.post(name: .fanControlOverride, object: nil, userInfo: ["reason": "high_temp"])
825:                     }
826:                 }
827:             }
828:         }
829: 
830:         let batteryAutoState = Store.shared.bool(key: "Sensors_fanBatteryAuto", defaultValue: false)
831:         if batteryAutoState {
832:             let isAC = await self.worker.isAC()
833:             if !isAC && updatedSensors.compactMap({ $0 as? Fan }).contains(where: { $0.mode == .forced }) {
834:                 await SMCHelper.shared.resetFanControl()
835:                 await MainActor.run {
836:                     NotificationCenter.default.post(name: .fanControlOverride, object: nil, userInfo: ["reason": "battery"])
837:                 }
838:             }
839:         }
840:         
841:         let newList = self.list
842:         newList.sensors = updatedSensors
843:         self.list = newList
844:         return newList
845:     }
846: 
847:     public func unknownCallback() {
848:         self.unknownSensorsStateLock.withLock { $0 = Store.shared.bool(key: "Sensors_unknown", defaultValue: false) }
849:     }
850: 
851:     public func HIDCallback() {
852:         let hidState = self.hidState
853:         let worker = self.worker
854:         Task {
855:             if hidState {
856:                 let sensors = await worker.getHIDSensors()
857:                 await MainActor.run {
858:                     self.list.sensors += sensors
859:                 }
860:             } else {
861:                 await MainActor.run {
862:                     self.list.sensors = self.list.sensors.filter({ $0.group != .hid })
863:                 }
864:             }
865:         }
866:     }
867: 
868:     public override func terminate() {
869:         let worker = self.worker
870:         Task {
871:             await worker.resetWorker()
872:         }
873:         super.terminate()
874:     }
875: }
