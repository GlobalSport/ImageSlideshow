//
//  ZoomablePhotoView.swift
//  ImageSlideshow
//
//  Created by Petr Zvoníček on 30.07.15.
//

import UIKit
import AVKit

/// Used to wrap a single slideshow item and allow zooming on it
@objcMembers
open class ImageSlideshowItem: UIScrollView, UIScrollViewDelegate {

    /// Image view to hold the image
    public let imageView = UIImageView()

    public let playerViewController = AVPlayerViewController()
    var player = AVPlayer()
    var playerThumbnailView = UIImageView()

    var playButton = UIButton()

    /// Activity indicator shown during image loading, when nil there won't be shown any
    public let activityIndicator: ActivityIndicatorView?

    /// Input Source for the item
    public let image: InputSource

    /// Guesture recognizer to detect double tap to zoom
    open var gestureRecognizer: UITapGestureRecognizer?

    /// Holds if the zoom feature is enabled
    public let zoomEnabled: Bool

    /// If set to true image is initially zoomed in
    open var zoomInInitially = false

    /// Maximum zoom scale
    open var maximumScale: CGFloat = 2.0

    fileprivate var lastFrame = CGRect.zero
    fileprivate var imageReleased = false
    fileprivate var isLoading = false
    fileprivate var singleTapGestureRecognizer: UITapGestureRecognizer?
    fileprivate var loadFailed = false {
        didSet {
            singleTapGestureRecognizer?.isEnabled = loadFailed
            gestureRecognizer?.isEnabled = !loadFailed
        }
    }

    /// Wraps around ImageView so RTL transformation on it doesn't interfere with UIScrollView zooming
    private let imageViewWrapper = UIView()

    // MARK: - Life cycle

    /**
        Initializes a new ImageSlideshowItem
        - parameter image: Input Source to load the image
        - parameter zoomEnabled: holds if it should be possible to zoom-in the image
    */
    init(image: InputSource, zoomEnabled: Bool, activityIndicator: ActivityIndicatorView? = nil, maximumScale: CGFloat = 2.0) {
        self.zoomEnabled = zoomEnabled
        self.image = image
        self.activityIndicator = activityIndicator
        self.maximumScale = maximumScale

        super.init(frame: CGRect.null)

        imageViewWrapper.addSubview(imageView)
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.isAccessibilityElement = true
        imageView.accessibilityTraits = .image
        if #available(iOS 11.0, *) {
            imageView.accessibilityIgnoresInvertColors = true
        }

        imageViewWrapper.clipsToBounds = true
        imageViewWrapper.isUserInteractionEnabled = true
        if UIApplication.shared.userInterfaceLayoutDirection == .rightToLeft {
            imageView.transform = CGAffineTransform(rotationAngle: CGFloat(Double.pi))
        }

        setPictoCenter()

        // scroll view configuration
        delegate = self
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        addSubview(imageViewWrapper)
        minimumZoomScale = 1.0
        maximumZoomScale = calculateMaximumScale()

        if let activityIndicator = activityIndicator {
            addSubview(activityIndicator.view)
        }

        // tap gesture recognizer
        let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(ImageSlideshowItem.tapZoom))
        tapRecognizer.numberOfTapsRequired = 2
        imageViewWrapper.addGestureRecognizer(tapRecognizer)
        gestureRecognizer = tapRecognizer

        singleTapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(retryLoadImage))
        singleTapGestureRecognizer!.numberOfTapsRequired = 1
        singleTapGestureRecognizer!.isEnabled = false
        imageViewWrapper.addGestureRecognizer(singleTapGestureRecognizer!)

        if let video = image as? VideoUrlSource,
            let url = URL(string: video.path) {
            self.player = AVPlayer(url: url)
            //self.player.addObserver(self, forKeyPath: "rate", options: NSKeyValueObservingOptions.new, context: nil)
            playerViewController.player = player

            if video.placeholder != nil || video.thumbnailUrl != nil {
                playerViewController.view.isHidden = true
                self.playButton = UIButton()
                playButton.translatesAutoresizingMaskIntoConstraints = false;
                self.addSubview(self.playButton)
                self.playButton.addTarget(self, action: #selector(playPressed), for: .touchUpInside)

                let bundle = Bundle(for: type(of: self))
                let imageBackground =  UIImage(named: "round_play", in: bundle, compatibleWith: nil)
                playButton.setImage(imageBackground, for: .normal)
                playButton.centerXAnchor.constraint(equalTo: imageView.centerXAnchor).isActive = true
                playButton.centerYAnchor.constraint(equalTo: imageView.centerYAnchor).isActive = true
                playButton.widthAnchor.constraint(equalToConstant: 50).isActive = true
                playButton.heightAnchor.constraint(equalToConstant: 50).isActive = true
            }

            self.addSubview(playerViewController.view)
            playerViewController.view.translatesAutoresizingMaskIntoConstraints = false
            playerViewController.view.centerXAnchor.constraint(equalTo: imageView.centerXAnchor).isActive = true
            playerViewController.view.centerYAnchor.constraint(equalTo: imageView.centerYAnchor).isActive = true
            playerViewController.view.widthAnchor.constraint(equalTo: imageView.widthAnchor).isActive = true
            playerViewController.view.heightAnchor.constraint(equalTo: imageView.heightAnchor).isActive = true
            playerViewController.allowsPictureInPicturePlayback = true
            playerViewController.delegate = self
        }

    }

    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override open func layoutSubviews() {
        super.layoutSubviews()

        if !zoomEnabled {
            imageViewWrapper.frame.size = frame.size
        } else if !isZoomed() {
            imageViewWrapper.frame.size = calculatePictureSize()
        }

        if isFullScreen() {
            clearContentInsets()
        } else {
            setPictoCenter()
        }

        self.activityIndicator?.view.center = imageViewWrapper.center

        // if self.frame was changed and zoomInInitially enabled, zoom in
        if lastFrame != frame && zoomInInitially {
            setZoomScale(maximumZoomScale, animated: false)
        }

        lastFrame = self.frame

        contentSize = imageViewWrapper.frame.size
        maximumZoomScale = calculateMaximumScale()
    }

    /// Request to load Image Source to Image View
    public func loadImage() {
        if self.imageView.image == nil && !isLoading {
            isLoading = true
            imageReleased = false
            activityIndicator?.show()
            image.load(to: self.imageView) {[weak self] image in
                // set image to nil if there was a release request during the image load
                if let imageRelease = self?.imageReleased, imageRelease {
                    self?.imageView.image = nil
                } else {
                    self?.imageView.image = image
                }
                self?.activityIndicator?.hide()
                self?.loadFailed = image == nil
                self?.isLoading = false

                self?.setNeedsLayout()
            }
        }
    }

    func releaseImage() {
        imageReleased = true
        cancelPendingLoad()
        self.imageView.image = nil
    }

    public func cancelPendingLoad() {
        image.cancelLoad?(on: imageView)
    }

    func retryLoadImage() {
        self.loadImage()
    }

    // MARK: - Image zoom & size

    func isZoomed() -> Bool {
        return self.zoomScale != self.minimumZoomScale
    }

    func zoomOut() {
        self.setZoomScale(minimumZoomScale, animated: false)
    }

    func tapZoom() {
        if isZoomed() {
            self.setZoomScale(minimumZoomScale, animated: true)
        } else {
            self.setZoomScale(maximumZoomScale, animated: true)
        }
    }

    fileprivate func screenSize() -> CGSize {
        return CGSize(width: frame.width, height: frame.height)
    }

    fileprivate func calculatePictureSize() -> CGSize {
        if let image = imageView.image, imageView.contentMode == .scaleAspectFit {
            let picSize = image.size
            let picRatio = picSize.width / picSize.height
            let screenRatio = screenSize().width / screenSize().height

            if picRatio > screenRatio {
                return CGSize(width: screenSize().width, height: screenSize().width / picSize.width * picSize.height)
            } else {
                return CGSize(width: screenSize().height / picSize.height * picSize.width, height: screenSize().height)
            }
        } else {
            return CGSize(width: screenSize().width, height: screenSize().height)
        }
    }

    fileprivate func calculateMaximumScale() -> CGFloat {
        return maximumScale
    }

    fileprivate func setPictoCenter() {
        var intendHorizon = (screenSize().width - imageViewWrapper.frame.width ) / 2
        var intendVertical = (screenSize().height - imageViewWrapper.frame.height ) / 2
        intendHorizon = intendHorizon > 0 ? intendHorizon : 0
        intendVertical = intendVertical > 0 ? intendVertical : 0
        contentInset = UIEdgeInsets(top: intendVertical, left: intendHorizon, bottom: intendVertical, right: intendHorizon)
    }

    private func isFullScreen() -> Bool {
        return imageViewWrapper.frame.width >= screenSize().width && imageViewWrapper.frame.height >= screenSize().height
    }

    func clearContentInsets() {
        contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    // MARK: UIScrollViewDelegate

    open func scrollViewDidZoom(_ scrollView: UIScrollView) {
        setPictoCenter()
    }

    open func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        return zoomEnabled ? imageViewWrapper : nil
    }

}

extension ImageSlideshowItem: AVPlayerViewControllerDelegate {

    @objc func playPressed() {
        self.playerViewController.view.isHidden = false
        self.player.play()
    }

    @objc func autoPlay() {
        if let video = self.image as? VideoUrlSource,
            video.autoPlay {
            playerViewController.view.isHidden = false
            player.play()
        }
    }

    @objc func pauseVideo() {
        self.player.pause()
    }

    open override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "rate" {
            if let player = object as? AVPlayer, player.rate == 1  {
                print("Playing")
                playerThumbnailView.isHidden = true
            }else{
                 print("Stop")
            }
        }
    }
}
