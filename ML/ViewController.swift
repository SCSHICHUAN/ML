import UIKit
import Vision
import CoreImage

class ViewController: UIViewController {
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - UI
    private let originalImageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.layer.borderWidth = 1
        iv.layer.borderColor = UIColor.lightGray.cgColor
        iv.clipsToBounds = true
        return iv
    }()

    /// 第二个：显示人像分割得到的黑白掩码（白=人像，黑=背景），方便直观看分割效果
    private let maskPreviewImageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.layer.borderWidth = 1
        iv.layer.borderColor = UIColor.lightGray.cgColor
        iv.clipsToBounds = true
        iv.backgroundColor = .white
        return iv
    }()

    private let personImageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.layer.borderWidth = 1
        iv.layer.borderColor = UIColor.lightGray.cgColor
        iv.clipsToBounds = true
        iv.backgroundColor = .white // 白色背景，方便看透明区域
        return iv
    }()

    private let backgroundImageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.layer.borderWidth = 1
        iv.layer.borderColor = UIColor.lightGray.cgColor
        iv.clipsToBounds = true
        iv.backgroundColor = .white // 白色背景（不使用黑色底）
        return iv
    }()

    private let selectImageButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.setTitle("选择图片", for: .normal)
        btn.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        btn.addTarget(self, action: #selector(selectImageTapped), for: .touchUpInside)
        btn.backgroundColor = .systemBlue
        btn.setTitleColor(.white, for: .normal)
        btn.layer.cornerRadius = 8
        return btn
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    private func setupUI() {
        view.backgroundColor = .white
        title = "人像背景分割"

        [originalImageView, maskPreviewImageView, personImageView, backgroundImageView, selectImageButton].forEach {
            view.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            selectImageButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            selectImageButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            selectImageButton.widthAnchor.constraint(equalToConstant: 120),
            selectImageButton.heightAnchor.constraint(equalToConstant: 44),

            originalImageView.topAnchor.constraint(equalTo: selectImageButton.bottomAnchor, constant: 20),
            originalImageView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            originalImageView.widthAnchor.constraint(equalToConstant: 150),
            originalImageView.heightAnchor.constraint(equalToConstant: 200),

            // 第二个：掩码黑白图
            maskPreviewImageView.topAnchor.constraint(equalTo: originalImageView.topAnchor),
            maskPreviewImageView.leadingAnchor.constraint(equalTo: originalImageView.trailingAnchor, constant: 20),
            maskPreviewImageView.widthAnchor.constraint(equalToConstant: 150),
            maskPreviewImageView.heightAnchor.constraint(equalToConstant: 200),

            // 其余的往后排：第三个=人像，第四个=背景，第五个=修复背景
            personImageView.topAnchor.constraint(equalTo: originalImageView.bottomAnchor, constant: 20),
            personImageView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            personImageView.widthAnchor.constraint(equalToConstant: 150),
            personImageView.heightAnchor.constraint(equalToConstant: 200),

            backgroundImageView.topAnchor.constraint(equalTo: personImageView.topAnchor),
            backgroundImageView.leadingAnchor.constraint(equalTo: personImageView.trailingAnchor, constant: 20),
            backgroundImageView.widthAnchor.constraint(equalToConstant: 150),
            backgroundImageView.heightAnchor.constraint(equalToConstant: 200)
        ])
    }

    @objc private func selectImageTapped() {
        let imagePicker = UIImagePickerController()
        imagePicker.sourceType = .photoLibrary
        imagePicker.delegate = self
        imagePicker.allowsEditing = false
        present(imagePicker, animated: true)
    }
}

// MARK: - 图片选择回调
extension ViewController: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
        picker.dismiss(animated: true)
        guard let selectedImage = info[.originalImage] as? UIImage else {
            showAlert(title: "错误", message: "未选择有效图片")
            return
        }
        separatePersonAndBackground(from: selectedImage)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }
}

// MARK: - 核心分割逻辑
extension ViewController {
    private func separatePersonAndBackground(from image: UIImage) {
        originalImageView.image = image
        maskPreviewImageView.image = nil
        personImageView.image = nil
        backgroundImageView.image = nil

        guard #available(iOS 15.0, *) else {
            showAlert(title: "不支持", message: "人像分割需要 iOS 15+（Vision 的 VNGeneratePersonSegmentationRequest）")
            return
        }

        // 统一图片方向，避免 Vision/合成坐标系不一致导致错位或全黑
        let inputImage = image.normalizedOrientation()
        guard let cgImage = inputImage.cgImage else {
            showAlert(title: "错误", message: "图片格式转换失败")
            return
        }

        let request = VNGeneratePersonSegmentationRequest { [weak self] req, err in
            guard let self = self else { return }
            if let err = err {
                self.showAlert(title: "错误", message: "分割失败: \(err.localizedDescription)")
                return
            }
            guard let result = req.results?.first as? VNPixelBufferObservation else {
                self.showAlert(title: "错误", message: "未获取到分割结果")
                return
            }
            let maskBuffer = result.pixelBuffer
            let mean = self.meanMaskValue(maskBuffer) // 是否有人
            
            // 从掩码中提取人像边界框坐标
            let personBoundingBox = self.extractPersonBoundingBox(from: maskBuffer, imageSize: inputImage.size)

            DispatchQueue.main.async {
                // 掩码几乎全黑/全白通常意味着没检测到人像，或该能力在当前环境不可用
                if mean < 0.01 {
                    self.showAlert(title: "未检测到人像", message: "分割掩码几乎全黑（mean=\(String(format: "%.4f", mean))）。请换一张有人像的照片，或在真机上运行（模拟器/部分设备可能不支持）。")
                } else if mean > 0.99 {
                    self.showAlert(title: "分割异常", message: "分割掩码几乎全白（mean=\(String(format: "%.4f", mean))）。请换图或在真机上重试。")
                }
                
                // 打印人像边界框坐标（归一化坐标，0~1）
                if let bbox = personBoundingBox {
                    print("人像边界框坐标: x=\(bbox.origin.x), y=\(bbox.origin.y), width=\(bbox.width), height=\(bbox.height)")
                }
                
                self.maskPreviewImageView.image = self.makeMaskPreviewImage(from: maskBuffer)
                self.personImageView.image = self.extractPerson(from: inputImage, mask: maskBuffer)
                self.backgroundImageView.image = self.extractBackground(from: inputImage, mask: maskBuffer)
            }
        }

        // 最高精度 + 8位灰度掩码
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        request.usesCPUOnly = false
        // 兼容性更强：明确使用当前可用的最高 revision
        if let rev = VNGeneratePersonSegmentationRequest.supportedRevisions.max() {
            request.revision = rev
        }

        // 传入 cgImage 开始请求
        DispatchQueue.global().async {
            // 使用已归一化方向的 cgImage，orientation 统一为 .up
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
            do {
                try handler.perform([request])
            } catch {
                DispatchQueue.main.async {
                    self.showAlert(title: "错误", message: "执行失败: \(error.localizedDescription)")
                }
            }
        }
    }

    /// 提取人物：保留掩码中白色（人物）区域
    private func extractPerson(from image: UIImage, mask: CVPixelBuffer) -> UIImage? {
        return applyMaskWithCoreImage(image: image, mask: mask, invertMask: true)
    }

    /// 提取背景：保留掩码中黑色（背景）区域
    private func extractBackground(from image: UIImage, mask: CVPixelBuffer) -> UIImage? {
        return applyMaskWithCoreImage(image: image, mask: mask, invertMask: false)
    }

    /// 用 Vision 输出的灰度掩码合成：用 `CIBlendWithMask` 以掩码亮度作为 alpha ,   invertMask = false 是人像
    private func applyMaskWithCoreImage(image: UIImage, mask: CVPixelBuffer, invertMask: Bool) -> UIImage? {
        // 用 cgImage 构造 CIImage，避免 CIImage(image:) 在 scale/extent 上出现不一致
        guard let cg = image.cgImage else { return nil }
        let inputCI = CIImage(cgImage: cg)
        let extent = inputCI.extent
        let maskCI = makeMaskCI(maskBuffer: mask, extent: extent, invert: invertMask) // 不取反人物区域是白色,白色是系统默认的

        // 前景是原图，背景是透明（这样“人像图”背景就是透明；“背景图”人像区域透明）
        let clearBG = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: extent)

        //取出白色遮罩对应的原图的像素
        let blended = inputCI.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: clearBG, // 空的背景图
                kCIInputMaskImageKey: maskCI // 蔗罩
            ]
        )

        guard let cgOut = ciContext.createCGImage(blended, from: extent) else { return nil }// 合并图层
        return UIImage(cgImage: cgOut, scale: image.scale, orientation: .up)
    }

    /// 将 Vision 输出的单通道灰度 mask 缩放到目标 extent，并可选反相 + 轻微羽化
    private func makeMaskCI(maskBuffer: CVPixelBuffer, extent: CGRect, invert: Bool) -> CIImage {
        var maskCI = CIImage(cvPixelBuffer: maskBuffer)

        // 将 mask 缩放到与 inputCI 同一 extent（像素坐标）
        let sx = extent.width / maskCI.extent.width
        let sy = extent.height / maskCI.extent.height
        maskCI = maskCI.transformed(by: CGAffineTransform(scaleX: sx, y: sy))

        // 防止缩放后边缘采样出界
        maskCI = maskCI
            .clampedToExtent()
            .cropped(to: extent)

        if invert {
            maskCI = maskCI.applyingFilter("CIColorInvert")
        }

        // 轻微平滑掩码边缘，减少锯齿（通常更好）
        maskCI = maskCI
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.5])
            .cropped(to: extent)

        return maskCI
    }

    /// 生成黑白掩码预览图（白=人像，黑=背景），直接显示在第二个 ImageView 里
    private func makeMaskPreviewImage(from buffer: CVPixelBuffer) -> UIImage? {
        let width = CGFloat(CVPixelBufferGetWidth(buffer))
        let height = CGFloat(CVPixelBufferGetHeight(buffer))
        let extent = CGRect(x: 0, y: 0, width: width, height: height)

        var maskCI = CIImage(cvPixelBuffer: buffer)
        maskCI = maskCI
            .clampedToExtent()
            .cropped(to: extent)

        // 提高一点对比度，让黑白更清晰（可选）
        maskCI = maskCI.applyingFilter(
            "CIColorControls",
            parameters: [
                kCIInputContrastKey: 1.2,
                kCIInputBrightnessKey: 0.0,
                kCIInputSaturationKey: 0.0 // 确保是黑白
            ]
        )

        guard let cgOut = ciContext.createCGImage(maskCI, from: extent) else { return nil }
        return UIImage(cgImage: cgOut, scale: 1.0, orientation: .up)
    }

    /// 计算掩码平均值（0~1）。用于快速判断“是否真的检测到了人像”
    private func meanMaskValue(_ buffer: CVPixelBuffer) -> Double {
        let ci = CIImage(cvPixelBuffer: buffer)
        let extent = ci.extent
        let avg = ci.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: extent)])
        var pixel = [UInt8](repeating: 0, count: 4)
        ciContext.render(avg, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        // 单通道掩码在转 RGBA 后各通道应接近，取 R 即可
        return Double(pixel[0]) / 255.0
    }
    
    /// 从掩码中提取人像的边界框坐标（归一化坐标，0~1）
    /// 返回的 CGRect 是相对于图片尺寸的归一化坐标（类似 Vision 的 boundingBox 格式）
    private func extractPersonBoundingBox(from buffer: CVPixelBuffer, imageSize: CGSize) -> CGRect? {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let threshold: UInt8 = 128 // 阈值：大于这个值认为是人像（白色区域）
        
        var minX = width
        var maxX = 0
        var minY = height
        var maxY = 0
        var foundPerson = false
        
        // 遍历掩码，找到所有白色（人像）像素的边界
        for y in 0..<height {
            let row = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let pixelValue = row[x]
                if pixelValue > threshold {
                    foundPerson = true
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
        }
        
        guard foundPerson else { return nil }
        
        // 转换为归一化坐标（0~1），Vision 标准格式
        let bbox = CGRect(
            x: CGFloat(minX) / CGFloat(width),
            y: CGFloat(minY) / CGFloat(height),
            width: CGFloat(maxX - minX + 1) / CGFloat(width),
            height: CGFloat(maxY - minY + 1) / CGFloat(height)
        )
        
        return bbox
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - Helpers
private extension UIImage {
    /// 将任意方向图片绘制为 `.up`，避免 Vision/CI 合成时坐标系不一致
    func normalizedOrientation() -> UIImage {
        if imageOrientation == .up { return self }
        UIGraphicsBeginImageContextWithOptions(size, false, scale)
        defer { UIGraphicsEndImageContext() }
        draw(in: CGRect(origin: .zero, size: size))
        return UIGraphicsGetImageFromCurrentImageContext() ?? self
    }
}
