/*
 * video_roi_display.cpp
 *
 * Subscribes to the "ovidds_frames" DDS topic and displays video in an
 * OpenCV window using the zzdds C++ bindings.
 *
 * Ported from the OpenDDS version.  Key differences from the pre-improvement
 * zzdds port:
 *
 *  - Listener base: DataReaderListenerBase (hand-rolled)       →  DDS::DataReaderListenerBase (generated)
 *  - Listener callbacks: (DDS_DataReader, const DDS_*Status&)  →  (shared_ptr<DDS::DataReader>, DDS::*Status)
 *  - Participant: one-shot UDP bootstrap                       →  generated DDS::DomainParticipantFactory
 *  - TypeSupport: ovidds_FrameTypeSupport                      →  ovidds::FrameTypeSupport  (A2)
 *  - Type name: "ovidds_Frame"                                 →  "ovidds::Frame"            (A1)
 *  - String params: const_cast<char*>(...)                     →  literal string direct       (A3)
 *  - entity creation: C ABI with nullptr QoS; C++ create_* also usable (D3)
 *
 * To get the ovidds::FrameDataReader typed wrapper inside on_data_available,
 * we call native_handle() directly on the shared_ptr<DDS::DataReader> — it is
 * now declared as a pure virtual on the abstract DataReader interface.
 *
 * No display in CI: imshow()/waitKey() need a real GUI backend (X11/Wayland),
 * which aborts rather than failing gracefully when $DISPLAY isn't set. This
 * skips them entirely in that case (or when OVIDDS_HEADLESS is set) and falls
 * back to periodic (not per-frame) stats logging instead -- exercising the
 * full DDS read path without a display. OVIDDS_RUN_SECONDS bounds the run for
 * CI instead of waiting on a 'q'/ESC keypress in a window that doesn't exist.
 */

#include <opencv2/highgui.hpp>
#include <opencv2/imgproc.hpp>

#include <atomic>
#include <chrono>
#include <cstdlib>
#include <ctime>
#include <iostream>
#include <mutex>
#include <sstream>
#include <thread>

#include "dcps_impl.hpp"
#include "zzdds_cpp.hpp"
#include "ovidds.hpp"

#include "ovidds_common.h"

using namespace cv;

namespace {

bool env_flag(const char* name) {
    const char* v = std::getenv(name);
    return v && *v && std::string(v) != "0";
}

int env_seconds(const char* name) {
    const char* v = std::getenv(name);
    if (!v || !*v) return 0;
    const int n = std::atoi(v);
    return n > 0 ? n : 0;
}

bool has_display() {
    const char* d = std::getenv("DISPLAY");
    return d && *d;
}

} // namespace

// ── DataReader listener ───────────────────────────────────────────────────────

class FrameReaderListener : public DDS::DataReaderListenerBase {
public:
    void on_subscription_matched(std::shared_ptr<::DDS::DataReader> /*the_reader*/,
                                 ::DDS::SubscriptionMatchedStatus status) override {
        const auto now  = std::chrono::system_clock::now();
        const auto tc   = std::chrono::system_clock::to_time_t(now);
        std::cout << "FrameReaderListener::on_subscription_matched() current_count="
                  << status.current_count << " @ " << std::ctime(&tc) << std::flush;
    }

    void on_data_available(std::shared_ptr<::DDS::DataReader> the_reader) override {
        ovidds::FrameDataReader frame_dr(the_reader->native_handle());

        ovidds::FrameDataReader::Loan loan;
        if (frame_dr.take_loaned(loan) != 1)
            return;

        std::unique_lock<std::mutex> lock(mutex_);
        if (loan.sample().info.valid_data) {
            frame_     = loan.sample().value;
            new_frame_ = true;
        }
        const size_t count = ++count_;
        lock.unlock();

        if (count % 10 == 0) {
            const auto now = std::chrono::system_clock::now();
            const auto tc  = std::chrono::system_clock::to_time_t(now);
            std::cout << "FrameReaderListener::on_data_available() count="
                      << count << " @ " << std::ctime(&tc) << std::flush;
        }
    }

    void on_requested_deadline_missed(std::shared_ptr<::DDS::DataReader> /*the_reader*/,
                                      ::DDS::RequestedDeadlineMissedStatus /*status*/) override {
        std::cout << "FrameReaderListener::on_requested_deadline_missed()" << std::endl;
    }

    void on_liveliness_changed(std::shared_ptr<::DDS::DataReader> /*the_reader*/,
                               ::DDS::LivelinessChangedStatus /*status*/) override {
        std::cout << "FrameReaderListener::on_liveliness_changed()" << std::endl;
    }

    void on_sample_lost(std::shared_ptr<::DDS::DataReader> /*the_reader*/,
                        ::DDS::SampleLostStatus /*status*/) override {
        std::cout << "FrameReaderListener::on_sample_lost()" << std::endl;
    }

    // Returns true if a new frame is available, populating mat and name.
    bool get_image(Mat& mat, std::string& name) {
        std::unique_lock<std::mutex> lock(mutex_);
        if (!new_frame_)
            return false;
        new_frame_ = false;
        if (!frame_.data.empty()) {
            std::ostringstream oss;
            oss << "Video Source " << frame_.source_id;
            name = oss.str();
            mat = Mat(frame_.size_y, frame_.size_x, frame_.type,
                      const_cast<uint8_t*>(frame_.data.data())).clone();
            return true;
        }
        return false;
    }

    size_t frames_received() const {
        std::unique_lock<std::mutex> lock(mutex_);
        return count_;
    }

private:
    mutable std::mutex mutex_;
    bool          new_frame_{false};
    size_t        count_{0};
    ovidds::Frame frame_{};
};

// ── main ──────────────────────────────────────────────────────────────────────

int main(int /*argc*/, char** /*argv*/)
{
    auto factory = zzdds::create_factory();
    if (!factory) {
        std::cerr << "Failed to create factory." << std::endl;
        return 1;
    }
    auto participant = factory->create_participant(
        static_cast<uint32_t>(DOMAIN), ::DDS::DomainParticipantQos{}, nullptr, 0);
    if (!participant) {
        std::cerr << "Failed to create participant." << std::endl;
        return 1;
    }
    DDS_DomainParticipant raw_part = participant->native_handle();

    if (ovidds::FrameTypeSupport::register_type(raw_part, FRAME_TYPE_NAME) != 0) {
        std::cerr << "Failed to register Frame type." << std::endl;
        return 1;
    }

    DDS_Topic topic = DDS_DomainParticipant_create_topic(
        raw_part, FRAME_TOPIC_NAME, FRAME_TYPE_NAME, nullptr, nullptr, 0);
    if (!topic) {
        std::cerr << "Failed to create topic." << std::endl;
        return 1;
    }

    DDS_Subscriber subscriber = DDS_DomainParticipant_create_subscriber(
        raw_part, nullptr, nullptr, 0);
    if (!subscriber) {
        std::cerr << "Failed to create subscriber." << std::endl;
        return 1;
    }

    // Must match video_capture's DataWriter reliability -- see that file's
    // comment for why RELIABLE is required for a Frame-sized (~900KB,
    // fragmented) sample to ever fully reassemble.
    DDS_DataReaderQos dr_qos{};
    DDS_Subscriber_get_default_datareader_qos(subscriber, &dr_qos);
    dr_qos.reliability.kind = DDS_ReliabilityQosPolicyKind_RELIABLE_RELIABILITY_QOS;

    auto listener = std::make_shared<FrameReaderListener>();
    DDS_DataReaderListener c_listener = listener->c_listener();

    DDS_TopicDescription topic_desc =
        DDS_DomainParticipant_lookup_topicdescription(raw_part, FRAME_TOPIC_NAME);
    DDS_DataReader raw_dr = DDS_Subscriber_create_datareader(
        subscriber, topic_desc, &dr_qos, &c_listener,
        DDS_DATA_AVAILABLE_STATUS | DDS_SUBSCRIPTION_MATCHED_STATUS);
    if (!raw_dr) {
        std::cerr << "Failed to create datareader." << std::endl;
        return 1;
    }

    const bool headless = env_flag("OVIDDS_HEADLESS") || !has_display();
    const int run_seconds = env_seconds("OVIDDS_RUN_SECONDS");

    if (headless) {
        std::cout << "No display available (or OVIDDS_HEADLESS set) -- running text-only, "
                     "logging periodic frame stats instead of showing a window."
                  << std::endl;
    }
    std::cout << "Created datareader, waiting for match." << std::endl;

    Mat         image;
    std::string name;
    const auto start = std::chrono::steady_clock::now();
    auto last_stats_at = start;

    while (true) {
        if (run_seconds > 0 &&
            std::chrono::steady_clock::now() - start >= std::chrono::seconds(run_seconds)) {
            std::cout << "OVIDDS_RUN_SECONDS=" << run_seconds << " elapsed, stopping." << std::endl;
            break;
        }

        if (headless) {
            listener->get_image(image, name); // drains new_frame_ so counts stay meaningful; image unused
            const auto now = std::chrono::steady_clock::now();
            if (now - last_stats_at >= std::chrono::seconds(5)) {
                const auto elapsed =
                    std::chrono::duration_cast<std::chrono::duration<double>>(now - start).count();
                std::cout << "stats: received " << listener->frames_received()
                          << " frames in " << elapsed << "s" << std::endl;
                last_stats_at = now;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
            continue;
        }

        if (listener->get_image(image, name))
            imshow(name, image);

        char c = static_cast<char>(waitKey(10));
        if (c == 27 || c == 'q' || c == 'Q')
            break;
    }

    std::cout << "video_roi_display: received " << listener->frames_received()
              << " frames total." << std::endl;

    participant->delete_contained_entities();
    factory->delete_participant(participant);

    return 0;
}
