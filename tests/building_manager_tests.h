// building_manager_tests.h
#include <gtest/gtest.h>

#include "building_manager.h"
#include "commodity_test_helper.h"

//- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
class BuildingManagerTests : public ::testing::Test {
 protected:
  CommodityTestHelper helper;
  cyclus::Builder builder1;
  cyclus::Builder builder2;
  cyclus::BuildingManager manager;
  double demand, capacity1, capacity2, cost1, cost2;
  int build1, build2;

 public:
  virtual void SetUp();  
  virtual void TearDown();
  void SetUpProblem();
};
