#include <chrono>
#include <memory>
#include <stdexcept>
#include <string>

#include <opencv2/videoio.hpp>
#include <rclcpp/rclcpp.hpp>
#include <sensor_msgs/msg/image.hpp>

#if __has_include(<cv_bridge/cv_bridge.hpp>)
#include <cv_bridge/cv_bridge.hpp>
#else
#include <cv_bridge/cv_bridge.h>
#endif

using namespace std::chrono_literals;

class JetsonAmcrestDriver : public rclcpp::Node
{
public:
  JetsonAmcrestDriver() : Node("jetson_amcrest_driver")
  {
    publisher_ = this->create_publisher<sensor_msgs::msg::Image>("camera/image_raw", 10);

    // Declarar parámetros nativos de ROS 2 (con tus valores por defecto)
    this->declare_parameter<std::string>("ip_camara", "172.16.5.182");
    this->declare_parameter<std::string>("usuario", "admin");
    this->declare_parameter<std::string>("contrasena", "cdmit2026");

    // Obtener los valores de los parámetros
    const std::string ip_camara = this->get_parameter("ip_camara").as_string();
    const std::string usuario = this->get_parameter("usuario").as_string();
    const std::string contrasena = this->get_parameter("contrasena").as_string();

    // Construcción limpia del pipeline idéntico al de gst-launch
    const std::string gst_pipeline =
      "rtspsrc location=\"rtsp://" + ip_camara + ":554/cam/realmonitor?channel=1&subtype=0\" "
      "user-id=" + usuario + " user-pw=" + contrasena + " latency=200 protocols=tcp ! "
      "rtph264depay ! h264parse ! queue ! nvv4l2decoder ! "
      "nvvidconv ! video/x-raw,format=BGRx ! videoconvert ! video/x-raw,format=BGR ! "
      "appsink drop=true max-buffers=1 sync=false";

    RCLCPP_INFO(
      this->get_logger(),
      "Iniciando captura RTSP en %s con aceleración por hardware NVIDIA NVDEC...",
      ip_camara.c_str());

    cap_.open(gst_pipeline, cv::CAP_GSTREAMER);

    if (!cap_.isOpened()) {
      RCLCPP_ERROR(this->get_logger(), "Could not open GStreamer pipeline");
      throw std::runtime_error("Pipeline failed");
    }

    // ~30 FPS (se crea después de abrir la cámara para no disparar el callback antes de tiempo)
    timer_ = this->create_wall_timer(33ms, std::bind(&JetsonAmcrestDriver::timer_callback, this));
  }

  ~JetsonAmcrestDriver() override
  {
    if (cap_.isOpened()) {
      cap_.release();
    }
  }

private:
  void timer_callback()
  {
    if (!cap_.grab()) {
      return;
    }

    cv::Mat frame;
    if (!cap_.retrieve(frame) || frame.empty()) {
      return;
    }

    std_msgs::msg::Header header;
    header.frame_id = "camera_link_optical";
    header.stamp = this->get_clock()->now();

    auto msg = cv_bridge::CvImage(header, "bgr8", frame).toImageMsg();
    publisher_->publish(*msg);
  }

  rclcpp::Publisher<sensor_msgs::msg::Image>::SharedPtr publisher_;
  rclcpp::TimerBase::SharedPtr timer_;
  cv::VideoCapture cap_;
};

int main(int argc, char ** argv)
{
  rclcpp::init(argc, argv);
  try {
    auto node = std::make_shared<JetsonAmcrestDriver>();
    rclcpp::spin(node);
  } catch (const std::exception & e) {
    RCLCPP_FATAL(rclcpp::get_logger("jetson_amcrest_driver"), "%s", e.what());
    rclcpp::shutdown();
    return 1;
  }
  rclcpp::shutdown();
  return 0;
}