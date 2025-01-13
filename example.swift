// example icon on SwiftUI
// adjust position and size to your needs
var body: some View {
                    VStack {
                        HStack {
                            Spacer()
                            Button(action: {
                                showDocumentPicker = true
                            }) {
                                Image(systemName: "folder.badge.plus")
                                    .font(.title)
                                    .padding()
                                    .background(Color.white.opacity(0.8))
                                    .foregroundColor(.blue)
                                    .clipShape(Circle())
                                    .shadow(radius: 4)
                            }
                            .padding()
                            .accessibilityLabel("Select Shapefile")
                        }
                        Spacer()
                    }
                .sheet(isPresented: $showDocumentPicker) {
                    DocumentPicker { result in
                        handleDocumentPickerResult(result)
                    }
                }
}

private func handleDocumentPickerResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            // Expecting .shp, .shx, .dbf, and .prj files
            let shpURLs = urls.filter { $0.pathExtension.lowercased() == "shp" }
            let shxURLs = urls.filter { $0.pathExtension.lowercased() == "shx" }
            let dbfURLs = urls.filter { $0.pathExtension.lowercased() == "dbf" }
            let prjURLs = urls.filter { $0.pathExtension.lowercased() == "prj" }

            guard let shpURL = shpURLs.first,
                  let shxURL = shxURLs.first,
                  let dbfURL = dbfURLs.first,
                  let prjURL = prjURLs.first else {
                print("Please select .shp, .shx, .dbf, and .prj files.")
                return
            }

            // Read the projection
            let reader = ShapefileReader(shpURL: shpURL, shxURL: shxURL)
            guard let projection = reader.readProjection(prjURL: prjURL) else {
                print("Failed to read projection information.")
                return
            }

            guard reader.isProjectionWGS84(prjContent: projection) else {
                print("Shapefile projection is not WGS84. Coordinate transformation is required.")
                // Implement coordinate transformation if needed
                return
            }

            // Read attributes
            let attributes = reader.readAttributes(dbfURL: dbfURL)

            // Read the shapefile geometries
            let geometries = reader.readShapefile()

            // Ensure the number of attributes matches the number of geometries
            guard attributes.count == geometries.count else {
                print("Mismatch between number of attributes and geometries.")
                return
            }

            // Update the map with new geometries and attributes
            DispatchQueue.main.async {
                for (index, geometry) in geometries.enumerated() {
                    let attribute = attributes[index]
                    switch geometry {
                    case .point(let coord):
                      // Processing Logic
                    case .polyLine(let coords):
                        // Example Logic
                        let cpolyline = CustomPolyline(coordinates: coords)
                        cpolyline.titleText = attribute["Name"]

                      case .multiLine(let lineStrings):
                        // Multiple linestrings example logic
                        for coords in lineStrings {
                            let cpolyline = CustomPolyline(coordinates: coords)
                            cpolyline.titleText = attribute["Name"]
                        }
                    case .polygon(let coords):
                        // Processing Logic
                    }
                }

                // Optionally, adjust the map region to fit the new shapefile
            }

        case .failure(let error):
            print("Failed to load shapefile: \(error.localizedDescription)")
        }
    }
