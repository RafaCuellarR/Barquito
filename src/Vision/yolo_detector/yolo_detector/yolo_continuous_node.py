import time

import numpy as np
import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, QoSHistoryPolicy, QoSReliabilityPolicy
from sensor_msgs.msg import Image
from vision_msgs.msg import Detection2DArray, Detection2D, ObjectHypothesisWithPose
from cv_bridge import CvBridge
from ultralytics import YOLO


class YoloContinuousNode(Node):
    """Runs YOLO on every incoming camera frame and publishes the detections.

    The subscription keeps only the newest frame (depth 1, best effort), so if
    inference is slower than the camera, old frames are dropped instead of
    queuing up and adding latency.
    """

    def __init__(self):
        super().__init__('yolo_continuous_node')
        self.declare_parameter('model', 'yolo11n.engine')
        self.declare_parameter('image_topic', '/camera/image_raw')
        self.declare_parameter('conf', 0.4)
        self.declare_parameter('imgsz', 640)
        self.declare_parameter('publish_image', True)
        # Upper limit on detections per second (0.0 = as fast as the model allows).
        # Pass decimals, e.g. max_fps:=5.0
        self.declare_parameter('max_fps', 0.0)
        # Seconds between the FPS / latency log lines
        self.declare_parameter('stats_period', 5.0)

        self.image_topic = self.get_parameter('image_topic').value
        self.model = YOLO(self.get_parameter('model').value, task='detect')
        self.bridge = CvBridge()

        # Warm up the model so the first real frame isn't slow
        self.model.predict(
            np.zeros((640, 640, 3), dtype='uint8'),
            imgsz=self.get_parameter('imgsz').value, verbose=False)

        qos = QoSProfile(
            history=QoSHistoryPolicy.KEEP_LAST,
            depth=1,
            reliability=QoSReliabilityPolicy.BEST_EFFORT)
        self.sub = self.create_subscription(Image, self.image_topic, self.on_image, qos)

        self.det_pub = self.create_publisher(Detection2DArray, 'detections', 10)
        self.img_pub = self.create_publisher(Image, 'detections/image', 10)

        self.last_run = 0.0
        self.stat_start = time.monotonic()
        self.stat_frames = 0
        self.stat_infer_time = 0.0
        self.last_count = 0
        self.create_timer(self.get_parameter('stats_period').value, self.report)

        self.get_logger().info(
            f'Continuous detection running on {self.image_topic}')

    def on_image(self, msg):
        max_fps = self.get_parameter('max_fps').value
        now = time.monotonic()
        if max_fps > 0.0 and (now - self.last_run) < 1.0 / max_fps:
            return
        self.last_run = now

        frame = self.bridge.imgmsg_to_cv2(msg, 'bgr8')

        t0 = time.perf_counter()
        res = self.model.predict(
            frame,
            conf=self.get_parameter('conf').value,
            imgsz=self.get_parameter('imgsz').value,
            verbose=False)[0]
        self.stat_infer_time += time.perf_counter() - t0
        self.stat_frames += 1

        out = Detection2DArray()
        out.header = msg.header
        for box, cls, score in zip(res.boxes.xywh.cpu().numpy(),
                                   res.boxes.cls.cpu().numpy(),
                                   res.boxes.conf.cpu().numpy()):
            d = Detection2D()
            d.header = msg.header
            d.bbox.center.position.x = float(box[0])
            d.bbox.center.position.y = float(box[1])
            d.bbox.size_x = float(box[2])
            d.bbox.size_y = float(box[3])
            hyp = ObjectHypothesisWithPose()
            hyp.hypothesis.class_id = res.names[int(cls)]
            hyp.hypothesis.score = float(score)
            d.results.append(hyp)
            out.detections.append(d)
        self.last_count = len(out.detections)
        self.det_pub.publish(out)

        if self.get_parameter('publish_image').value:
            annotated = self.bridge.cv2_to_imgmsg(res.plot(), 'bgr8')
            annotated.header = msg.header
            self.img_pub.publish(annotated)

    def report(self):
        elapsed = time.monotonic() - self.stat_start
        if self.stat_frames == 0:
            self.get_logger().warn(
                f'No frames processed in the last {elapsed:.0f}s. '
                f'Is {self.image_topic} publishing?')
        else:
            self.get_logger().info(
                f'{self.stat_frames / elapsed:.1f} FPS | '
                f'inference avg {1000.0 * self.stat_infer_time / self.stat_frames:.1f} ms | '
                f'last frame: {self.last_count} detections')
        self.stat_start = time.monotonic()
        self.stat_frames = 0
        self.stat_infer_time = 0.0


def main():
    rclpy.init()
    node = YoloContinuousNode()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()