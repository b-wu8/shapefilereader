import Foundation
import MapKit

enum ShapeType: Int32 {
    case nullShape = 0
    case point = 1
    case polyLine = 3
    case polygon = 5
    case multiPoint = 8
    case polylineM = 23
}

struct ShapefileHeader {
    let fileCode: Int32
    let fileLength: Int32
    let version: Int32
    let shapeType: ShapeType
    let boundingBox: BoundingBox
    let entityCount: Int32
}

struct BoundingBox {
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double
}

struct ShapeRecord {
    let recordNumber: Int32
    let contentLength: Int32
    let shapeType: ShapeType
    let geometry: Geometry
}

enum Geometry {
    case point(CLLocationCoordinate2D)
    case polyLine([CLLocationCoordinate2D])
    case polygon([CLLocationCoordinate2D])
    case multiLine([[CLLocationCoordinate2D]])

    static func nullShapeGeometry() -> Geometry {
        return .point(CLLocationCoordinate2D(latitude: 0, longitude: 0))
    }
}

struct DBFField {
    let name: String
    let length: Int
}

class ShapefileReader {
    let shpURL: URL
    let shxURL: URL

    init(shpURL: URL, shxURL: URL) {
        self.shpURL = shpURL
        self.shxURL = shxURL
    }

    func readShapefile() -> [Geometry] {
        guard let shpData = try? Data(contentsOf: shpURL),
              let shxData = try? Data(contentsOf: shxURL) else {
            fatalError("Failed to read .shp or .shx files.")
        }

        let (entityCount, recordOffsets) = parseShx(shxData: shxData)
        let shpReader = ShpDataReader(shpData: shpData, recordOffsets: recordOffsets)
        let header = shpReader.readHeader(entityCount: entityCount)
        print("Shape Type from header: \(header.shapeType)")
        print("Entity Count: \(header.entityCount)")

        var geometries: [Geometry] = []
        for i in 0..<header.entityCount {
            if let record = shpReader.readRecord() {
                geometries.append(record.geometry)
            } else {
                print("Warning: Failed to read shape record at index \(i).")
            }
        }
        return geometries
    }

    private func parseShx(shxData: Data) -> (Int32, [Int]) {
        if shxData.count < 100 {
            fatalError("Invalid .shx file: not enough data for header.")
        }

        let numberOfRecords = (shxData.count - 100) / 8
        var recordOffsets: [Int] = []

        var cursor = shxData.startIndex
        cursor += 100 // skip header

        for _ in 0..<numberOfRecords {
            let offset = shxData.readInt32(at: cursor)
            cursor += 4
            _ = shxData.readInt32(at: cursor)
            cursor += 4

            let byteOffset = Int(offset) * 2
            recordOffsets.append(byteOffset)
        }

        return (Int32(numberOfRecords), recordOffsets)
    }

    func readProjection(prjURL: URL) -> String? {
        do {
            let prjContent = try String(contentsOf: prjURL, encoding: .utf8)
            return prjContent
        } catch {
            print("Failed to read .prj file: \(error)")
            return nil
        }
    }

    func isProjectionWGS84(prjContent: String) -> Bool {
        return prjContent.contains("WGS_1984")
    }

    func readAttributes(dbfURL: URL) -> [[String: String]] {
        guard let dbfData = try? Data(contentsOf: dbfURL) else {
            print("Failed to read .dbf file.")
            return []
        }

        var cursor = dbfData.startIndex

        // DBF Header
        _ = dbfData[cursor]; cursor += 1
        _ = dbfData[cursor]; cursor += 1
        _ = dbfData[cursor]; cursor += 1
        _ = dbfData[cursor]; cursor += 1

        let numberOfRecords = Int32(littleEndian: dbfData[cursor..<(cursor+4)].withUnsafeBytes { $0.load(as: Int32.self) })
        cursor += 4

        cursor += 2
        let recordLength = Int16(littleEndian: dbfData[cursor..<(cursor+2)].withUnsafeBytes { $0.load(as: Int16.self) })
        cursor += 2
        cursor += 20

        var fields: [DBFField] = []
        while cursor < dbfData.endIndex && dbfData[cursor] != 0x0D {
            let fieldNameBytes = dbfData[cursor..<(cursor+11)]
            let fieldName = String(bytes: fieldNameBytes.prefix { $0 != 0 }, encoding: .ascii) ?? "Unknown"
            cursor += 11

            cursor += 1 // fieldType
            cursor += 4 // field data address
            let fieldLength = Int(dbfData[cursor])
            cursor += 1

            cursor += 1 // decimalCount
            cursor += 14 // reserved
            fields.append(DBFField(name: fieldName, length: fieldLength))
        }
        cursor += 1 // skip terminator

        var records: [[String: String]] = []
        for _ in 0..<numberOfRecords {
            if cursor + Int(recordLength) > dbfData.endIndex { break }

            let recordData = dbfData[cursor..<cursor + Int(recordLength)]
            cursor += Int(recordLength)

            var record: [String: String] = [:]
            var recordCursor = recordData.startIndex + 1
            for field in fields {
                let endIndex = recordCursor + field.length
                if endIndex <= recordData.endIndex {
                    let valueData = recordData[recordCursor..<endIndex]
                    let value = String(bytes: valueData, encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    record[field.name] = value
                    recordCursor = endIndex
                } else {
                    record[field.name] = ""
                }
            }
            records.append(record)
        }

        return records
    }
}

class ShpDataReader {
    let shpData: Data
    let recordOffsets: [Int]
    var currentRecordIndex = 0
    var shapeType: ShapeType = .nullShape
    var entityCount: Int32 = 0

    init(shpData: Data, recordOffsets: [Int]) {
        self.shpData = shpData
        self.recordOffsets = recordOffsets
    }

    func readHeader(entityCount: Int32) -> ShapefileHeader {
        var cursor = shpData.startIndex

        let fileCode = shpData.readInt32(at: cursor)
        cursor += 4

        cursor += 20 // skip

        let fileLength = shpData.readInt32(at: cursor)
        cursor += 4

        guard let versionVal = shpData.readInt32LittleEndian(at: cursor) else {
            fatalError("Failed to read version from shapefile header.")
        }
        let version = versionVal
        cursor += 4

        guard let shapeTypeVal = shpData.readInt32LittleEndian(at: cursor) else {
            fatalError("Failed to read shapeType from shapefile header.")
        }
        guard let st = ShapeType(rawValue: shapeTypeVal) else {
            fatalError("Invalid shapeType \(shapeTypeVal).")
        }
        shapeType = st
        cursor += 4

        let minX = shpData.readDoubleLittleEndianSafe(at: cursor); cursor += 8
        let minY = shpData.readDoubleLittleEndianSafe(at: cursor); cursor += 8
        let maxX = shpData.readDoubleLittleEndianSafe(at: cursor); cursor += 8
        let maxY = shpData.readDoubleLittleEndianSafe(at: cursor); cursor += 8

        let boundingBox = BoundingBox(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
        self.entityCount = entityCount

        return ShapefileHeader(fileCode: fileCode, fileLength: fileLength, version: version, shapeType: shapeType, boundingBox: boundingBox, entityCount: entityCount)
    }

    func readRecord() -> ShapeRecord? {
        guard currentRecordIndex < recordOffsets.count else {
            return nil
        }

        let offset = recordOffsets[currentRecordIndex]
        currentRecordIndex += 1

        var cursor = shpData.startIndex + offset
        print("Reading record at offset \(offset), cursor=\(cursor), data.count=\(shpData.count)")

        guard cursor + 8 <= shpData.endIndex else {
            print("Not enough data for record header at offset \(offset).")
            return nil
        }

        let recordNumber = shpData.readInt32(at: cursor); cursor += 4
        let contentLength = shpData.readInt32(at: cursor); cursor += 4
        let byteLength = Int(contentLength) * 2
        print("Record number: \(recordNumber), contentLength (words): \(contentLength), byteLength: \(byteLength)")

        guard cursor + byteLength <= shpData.endIndex else {
            print("Record extends beyond file end.")
            return nil
        }

        let recordData = shpData[cursor..<(cursor + byteLength)]
        let recordReader = RecordDataReader(data: recordData)

        let shapeTypeVal = recordReader.readInt32LittleEndian()
        print("ShapeTypeVal for this record: \(shapeTypeVal)")
        guard let shapeType = ShapeType(rawValue: shapeTypeVal) else {
            print("Unknown shape type \(shapeTypeVal).")
            return nil
        }
        print("Identified shape type: \(shapeType)")

        var geometry: Geometry = .nullShapeGeometry()

        switch shapeType {
        case .point:
            if !recordReader.canReadBytes(16) {
                print("Not enough data for point coordinates.")
                return nil
            }
            let x = recordReader.readDoubleLittleEndian()
            let y = recordReader.readDoubleLittleEndian()
            geometry = .point(CLLocationCoordinate2D(latitude: y, longitude: x))

        case .polyLine, .polygon, .polylineM:
            // boundingBox
            if !recordReader.canReadBytes(32) {
                print("Not enough data for bounding box.")
                return nil
            }
            _ = recordReader.readBoundingBox()

            if !recordReader.canReadBytes(8) {
                print("Not enough data for numParts/numPoints.")
                return nil
            }
            let numParts = Int(recordReader.readInt32LittleEndian())
            let numPoints = Int(recordReader.readInt32LittleEndian())

            // parts array
            let partsBytes = numParts * 4
            if !recordReader.canReadBytes(partsBytes) {
                print("Not enough data for parts array.")
                return nil
            }
            let parts = recordReader.readInt32Array(count: numParts)

            // points array
            let pointsBytesNeeded = numPoints * 16
            let actualPointsBytes = recordReader.remainingBytes()
            let actualNumPoints = min(numPoints, actualPointsBytes/16)
            if actualNumPoints < numPoints {
                print("Not enough data for all declared points. Declared: \(numPoints), can read: \(actualNumPoints)")
            }
            let points = recordReader.readPoints(count: actualNumPoints)

            // If polylineM, try reading M values if possible
            if shapeType == .polylineM {
                let afterPoints = recordReader.remainingBytes()
                // M arrays: need at least 16 bytes for Mmin/Mmax
                if afterPoints >= 16 {
                    let mMin = recordReader.readDoubleLittleEndian()
                    let mMax = recordReader.readDoubleLittleEndian()
                    let mArrayBytes = actualNumPoints * 8
                    if recordReader.remainingBytes() >= mArrayBytes {
                        // Read M array
                        for _ in 0..<actualNumPoints {
                            _ = recordReader.readDoubleLittleEndian()
                        }
                    } else {
                        print("Not enough data for full M array, skipping M array.")
                    }
                } else {
                    print("Not enough data for Mmin/Mmax, skipping M arrays.")
                }
            }

            // Construct geometry
            var lineSegments: [[CLLocationCoordinate2D]] = []
            for pIndex in 0..<numParts {
                let start = Int(parts[pIndex])
                let end = (pIndex < numParts - 1) ? Int(parts[pIndex + 1]) : actualNumPoints
                if start < end && start < points.count && end <= points.count {
                    lineSegments.append(Array(points[start..<end]))
                } else {
                    print("Part indices out of range, skipping this part.")
                }
            }

            switch shapeType {
            case .polyLine, .polylineM:
                geometry = (lineSegments.count == 1) ? .polyLine(lineSegments[0]) : .multiLine(lineSegments)
            case .polygon:
                geometry = (lineSegments.count == 1) ? .polygon(lineSegments[0]) : .polygon(lineSegments.flatMap { $0 })
            default:
                break
            }

        case .nullShape:
            break

        default:
            print("Shape type \(shapeType) not fully supported.")
            break
        }

        return ShapeRecord(recordNumber: recordNumber, contentLength: contentLength, shapeType: shapeType, geometry: geometry)
    }
}

class RecordDataReader {
    let data: Data
    var cursor: Data.Index

    init(data: Data) {
        self.data = data
        self.cursor = data.startIndex
    }

    func canReadBytes(_ count: Int) -> Bool {
        return (cursor + count) <= data.endIndex
    }

    func remainingBytes() -> Int {
        return data.endIndex - cursor
    }

    func readInt32LittleEndian() -> Int32 {
        guard let value = data.readInt32LittleEndian(at: cursor) else {
            fatalError("Failed to read Int32 at cursor \(cursor). Data size: \(data.count)")
        }
        cursor += 4
        return value
    }

    func readDoubleLittleEndian() -> Double {
        if !canReadBytes(8) {
            fatalError("Not enough data to read double at \(cursor). Data size: \(data.count)")
        }
        let value = data.readDoubleLittleEndianSafe(at: cursor)
        cursor += 8
        return value
    }

    func readBoundingBox() -> BoundingBox {
        let minX = readDoubleLittleEndian()
        let minY = readDoubleLittleEndian()
        let maxX = readDoubleLittleEndian()
        let maxY = readDoubleLittleEndian()
        return BoundingBox(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    func readInt32Array(count: Int) -> [Int32] {
        var array: [Int32] = []
        for _ in 0..<count {
            array.append(readInt32LittleEndian())
        }
        return array
    }

    func readPoints(count: Int) -> [CLLocationCoordinate2D] {
        var points: [CLLocationCoordinate2D] = []
        let actualCount = min(count, remainingBytes()/16)
        for _ in 0..<actualCount {
            let x = readDoubleLittleEndian()
            let y = readDoubleLittleEndian()
            points.append(CLLocationCoordinate2D(latitude: y, longitude: x))
        }
        return points
    }
}

extension Data {
    func readInt32(at index: Data.Index) -> Int32 {
        let range = index..<(index+4)
        guard range.upperBound <= self.endIndex else {
            fatalError("Not enough data to read Int32 at \(index). Size: \(self.count)")
        }
        var buffer = [UInt8](repeating: 0, count: 4)
        self.copyBytes(to: &buffer, from: range)
        let value = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        return Int32(bigEndian: value)
    }

    func readInt32LittleEndian(at index: Data.Index) -> Int32? {
        let range = index..<(index+4)
        guard range.upperBound <= self.endIndex else {
            print("Not enough data to read Int32 at index \(index). Data count: \(self.count)")
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: 4)
        self.copyBytes(to: &buffer, from: range)
        let value = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        return Int32(littleEndian: value)
    }

    func readDoubleLittleEndianSafe(at index: Data.Index) -> Double {
        let range = index..<(index+8)
        guard range.upperBound <= self.endIndex else {
            // Instead of crashing, print and return 0.0
            print("Not enough data to read Double at \(index). Data size: \(self.count). Returning 0.0 and skipping.")
            return 0.0
        }

        var buffer = [UInt8](repeating: 0, count: 8)
        self.copyBytes(to: &buffer, from: range)

        let value: UInt64 = buffer.withUnsafeBytes { rawPtr in
            let v = rawPtr.load(as: UInt64.self)
            return UInt64(littleEndian: v)
        }

        return Double(bitPattern: value)
    }
}
