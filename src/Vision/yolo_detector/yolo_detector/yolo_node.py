import json

import rclpy
from rclpy.node import Node
from rclpy.qos import qos_profile_sensor_data
from sensor_msgs.msg import Image
from std_srvs.srv import Trigger
from vision_msgs.msg import Detection2DArray, Detection2D, ObjectHypothesisWithPose
from cv_bridge import CvBridge
from ultralytics import YOLO


class YoloServiceNode(Node):
    """Keeps the most recent camera frame and runs YOLO only when the
    'detect' service is called."""

    def __init__(self):
        super().__init__('yolo_node')
        self.declare_parameter('model', 'yolo11n.engine')
        self.declare_parameter('conf', 0.4)
        self.declare_parameter('imgsz', 640)
        self.declare_parameter('publish_image', True)
        # Reject frames older than this many seconds (0 = never reject)
        self.declare_parameter('max_frame_age', 2.0)

        self.model = YOLO(self.get_parameter('model').value, task='detect')
        self.bridge = CvBridge()

        self.last_msg = None
        self.last_msg_time = None

        # The subscription only stores the newest frame (cheap, no inference)
        self.sub = self.create_subscription(
            Image, '/camera/image_raw', self.on_image, qos_profile_sensor_data)

        self.det_pub = self.create_publisher(Detection2DArray, 'detections', 10)
        self.img_pub = self.create_publisher(Image, 'detections/image', 10)
        self.srv = self.create_service(Trigger, 'detect', self.on_detect)

        # Warm up the engine so the first real call isn't slow
        self.model.predict(
            __import__('numpy').zeros((640, 640, 3), dtype='uint8'),
            imgsz=self.get_parameter('imgsz').value, verbose=False)

        self.get_logger().info(
            "YOLO service ready: call 'detect' (std_srvs/Trigger). "
            "Listening on image_raw.")

    def on_image(self, msg):
        self.last_msg = msg
        self.last_msg_time = self.get_clock().now()

    def on_detect(self, request, response):
        if self.last_msg is None:
            response.success = False
            response.message = 'No image received yet on image_raw'
            return response

        max_age = self.get_parameter('max_frame_age').value
        if max_age > 0:
            age = (self.get_clock().now() - self.last_msg_time).nanoseconds / 1e9
            if age > max_age:
                response.success = False
                response.message = (
                    f'Last frame is {age:.1f}s old (max {max_age}s). '
                    'Is the camera still publishing?')
                return response

        msg = self.last_msg
        frame = self.bridge.imgmsg_to_cv2(msg, 'bgr8')
        res = self.model.predict(
            frame,
            conf=self.get_parameter('conf').value,
            imgsz=self.get_parameter('imgsz').value,
            verbose=False)[0]

        out = Detection2DArray()
        out.header = msg.header
        summary = []
        for box, cls, score in zip(res.boxes.xywh.cpu().numpy(),
                                   res.boxes.cls.cpu().numpy(),
                                   res.boxes.conf.cpu().numpy()):
            name = res.names[int(cls)]
            d = Detection2D()
            d.header = msg.header
            d.bbox.center.position.x = float(box[0])
            d.bbox.center.position.y = float(box[1])
            d.bbox.size_x = float(box[2])
            d.bbox.size_y = float(box[3])
            hyp = ObjectHypothesisWithPose()
            hyp.hypothesis.class_id = name
            hyp.hypothesis.score = float(score)
            d.results.append(hyp)
            out.detections.append(d)
            summary.append({
                'class': name,
                'score': round(float(score), 3),
                'cx': round(float(box[0]), 1),
                'cy': round(float(box[1]), 1),
                'w': round(float(box[2]), 1),
                'h': round(float(box[3]), 1),
            })
        self.det_pub.publish(out)

        if self.get_parameter('publish_image').value:
            annotated = self.bridge.cv2_to_imgmsg(res.plot(), 'bgr8')
            annotated.header = msg.header
            self.img_pub.publish(annotated)

        response.success = True
        response.message = json.dumps(summary)
        return response


def main():
    rclpy.init()
    node = YoloServiceNode()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()