#include "Misc/AutomationTest.h"


class NIMFORUEBINDINGS_API FNimTestBase : public FAutomationTestBase {

	FString TestName;
public:
	
	FNimTestBase(FString InName) : FAutomationTestBase(InName, false) {
		TestName = InName;
	}
	
	FNimTestBase() :FAutomationTestBase("InName", false) {
	}

	void (*ActualTest) (FNimTestBase&);

	void ReloadTest();
	
	virtual uint32 GetTestFlags() const override {
		//At some point expose these
		return  EAutomationTestFlags::EditorContext | EAutomationTestFlags::SmokeFilter;;
	}
	virtual FString GetBeautifiedTestName() const override {
		return TestName;
	}
	virtual bool RunTest(const FString& Parameters) override {
		if(ActualTest!=nullptr) {
			ActualTest(*this);
		}
		return true;
	}
	virtual bool IsStressTest() const { return false; }
	
	virtual uint32 GetRequiredDeviceNum() const override { return 1; } 
	virtual FString GetTestSourceFileName() const override { return "Whatever.cpp"; } 
	virtual int32 GetTestSourceFileLine() const override { return 10; } 
protected: 
	virtual void GetTests(TArray<FString>& OutBeautifiedNames, TArray <FString>& OutTestCommands) const override 
	{ 
		OutBeautifiedNames.Add(TestName); 
		OutTestCommands.Add(FString());
		
	}

};

