/*
 * roi_generator.cpp
 *
 * Standalone face detection using OpenCV's DetectionBasedTracker.
 * No DDS involvement — unchanged from the original ovidds version except for
 * fixing the cascade file paths (adjust for your system).
 */

#include <opencv2/highgui.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/objdetect.hpp>
#include <opencv2/videoio.hpp>

#include <iostream>
#include <string>
#include <vector>

const std::string WindowName("Face Detection");

using namespace cv;

class CascadeDetectorAdapter : public DetectionBasedTracker::IDetector {
public:
    explicit CascadeDetectorAdapter(cv::Ptr<cv::CascadeClassifier> detector)
        : IDetector(), detector_(detector)
    {
        CV_Assert(detector);
    }

    void detect(const cv::Mat& image, std::vector<cv::Rect>& objects) override {
        detector_->detectMultiScale(image, objects, scaleFactor, minNeighbours, 0, minObjSize, maxObjSize);
    }

    virtual ~CascadeDetectorAdapter() = default;

private:
    CascadeDetectorAdapter() = delete;
    cv::Ptr<cv::CascadeClassifier> detector_;
};

static cv::Ptr<DetectionBasedTracker> make_tracker(const std::string& cascade_file) {
    auto cc1 = cv::makePtr<cv::CascadeClassifier>(cascade_file);
    if (cc1->empty()) {
        std::cerr << "Cannot load cascade: " << cascade_file << std::endl;
        return {};
    }
    auto main_det = cv::makePtr<CascadeDetectorAdapter>(cc1);
    auto cc2 = cv::makePtr<cv::CascadeClassifier>(cascade_file);
    auto track_det = cv::makePtr<CascadeDetectorAdapter>(cc2);
    DetectionBasedTracker::Parameters params;
    return cv::makePtr<DetectionBasedTracker>(main_det, track_det, params);
}

int main(int /*argc*/, char** /*argv*/)
{
    namedWindow(WindowName);

    VideoCapture capture;
    if (!capture.open(0, cv::CAP_ANY) || !capture.isOpened()) {
        std::cerr << "Cannot open camera." << std::endl;
        return 1;
    }

    const std::string lbp_cascade  = "/usr/share/opencv4/lbpcascades/lbpcascade_frontalface.xml";
    const std::string haar_cascade = "/usr/share/opencv4/haarcascades/haarcascade_frontalface_default.xml";

    auto det1 = make_tracker(lbp_cascade);
    auto det2 = make_tracker(haar_cascade);
    if (!det1 || !det2) return 2;

    if (!det1->run() || !det2->run()) {
        std::cerr << "Detector initialisation failed." << std::endl;
        return 2;
    }

    Mat frame, gray;
    std::vector<Rect> faces1, faces2;

    while (true) {
        capture >> frame;
        if (frame.empty()) break;

        cvtColor(frame, gray, COLOR_BGR2GRAY);
        det1->process(gray); det1->getObjects(faces1);
        det2->process(gray); det2->getObjects(faces2);

        for (const auto& r : faces1) rectangle(frame, r, Scalar(0, 255, 0));
        for (const auto& r : faces2) rectangle(frame, r, Scalar(0, 0, 255));

        imshow(WindowName, frame);
        char c = static_cast<char>(waitKey(10));
        if (c == 27 || c == 'q' || c == 'Q') break;
    }

    det1->stop();
    det2->stop();
    return 0;
}
