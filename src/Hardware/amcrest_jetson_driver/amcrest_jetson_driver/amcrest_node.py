import rclpy
from rclpy.node import Node
from sensor_msgs.msg import Image
import cv2
from cv_bridge import CvBridge

class JetsonAmcrestDriver(Node):
    def __init__(self):
        super().__init__('jetson_amcrest_driver')
        self.publisher_ = self.create_publisher(Image, 'camera/image_raw', 10)
        self.timer = self.create_timer(0.033, self.timer_callback) # ~30 FPS
        self.bridge = CvBridge()
        
        # Declarar parámetros nativos de ROS 2 (con tus valores por defecto)
        self.declare_parameter('ip_camara', '192.168.1.108')
        self.declare_parameter('usuario', 'admin')
        self.declare_parameter('contrasena', 'cdmit2026')
        
        # Obtener los valores de los parámetros
        ip_camara = self.get_parameter('ip_camara').get_parameter_value().string_value
        usuario = self.get_parameter('usuario').get_parameter_value().string_value
        contrasena = self.get_parameter('contrasena').get_parameter_value().string_value
        
        # Construcción limpia del pipeline idéntico al de gst-launch
        gst_pipeline = (
            f"rtspsrc location=rtsp://{ip_camara}:554/cam/realmonitor?channel=1&subtype=0 "
            f"user-id={usuario} user-pw={contrasena} latency=200 protocols=tcp ! "
            f"rtph264depay ! h264parse ! queue ! nvv4l2decoder low-latency-mode=true disable-dpb=true ! "
            f"nvvidconv ! video/x-raw, format=BGRx ! videoconvert ! video/x-raw, format=BGR ! appsink drop=true max-buffers=1"
        )
        
        self.get_logger().info(f"Iniciando captura RTSP en {ip_camara} con aceleración por hardware NVIDIA NVDEC...")
        self.cap = cv2.VideoCapture(gst_pipeline, cv2.CAP_GSTREAMER)
        
        if not self.cap.isOpened():
            self.get_logger().error("ERROR CRÍTICO: No se pudo abrir el pipeline de GStreamer.")

    def timer_callback(self):
        if self.cap.grab():
            ret, frame = self.cap.retrieve()
            if ret:
                msg = self.bridge.cv2_to_imgmsg(frame, encoding="bgr8")
                msg.header.frame_id = "camera_link_optical"
                msg.header.stamp = self.get_clock().now().to_msg()
                self.publisher_.publish(msg)

def main(args=None):
    rclpy.init(args=args)
    node = JetsonAmcrestDriver()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    node.cap.release()
    node.destroy_node()
    rclpy.shutdown()

if __name__ == '__main__':
    main()
