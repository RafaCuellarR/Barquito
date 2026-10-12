cmake_minimum_required(VERSION 3.8)
project(amcrest_driver)

if(CMAKE_COMPILER_IS_GNUCXX OR CMAKE_CXX_COMPILER_ID MATCHES "Clang")
  add_compile_options(-Wall -Wextra -Wpedantic)
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(ament_cmake REQUIRED)
find_package(rclcpp REQUIRED)
find_package(sensor_msgs REQUIRED)
find_package(std_msgs REQUIRED)
find_package(cv_bridge REQUIRED)
find_package(OpenCV REQUIRED COMPONENTS core videoio)

install(
  DIRECTORY launch/
  DESTINATION share/${PROJECT_NAME}/launch
)

add_executable(amcrest_camera_node src/amcrest_camera_node.cpp)
ament_target_dependencies(amcrest_camera_node
  rclcpp
  sensor_msgs
  std_msgs
  cv_bridge
)
target_include_directories(amcrest_camera_node PRIVATE ${OpenCV_INCLUDE_DIRS})
target_link_libraries(amcrest_camera_node ${OpenCV_LIBS})

install(TARGETS amcrest_camera_node
  DESTINATION lib/${PROJECT_NAME}
)

ament_package()