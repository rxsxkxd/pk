package common

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const completeInventory = `{
  "aws_region": "ap-northeast-1",
  "DBInstances": [
    {
      "DBInstanceIdentifier": "blue",
      "Engine": "mysql",
      "EngineVersion": "8.0.43",
      "DBInstanceClass": "db.t4g.small",
      "ParameterApplyStatus": "in-sync",
      "DBParameterGroups": [{"DBParameterGroupName": "blue-v1", "ParameterApplyStatus": "in-sync"}]
    }
  ],
  "ParameterGroups": {"blue-v1": {"Parameters": {"time_zone": {"Value": "UTC", "Source": "engine-default"}}}}
}`

func writeInventoryFile(t *testing.T, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "inventory.json")
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}
	return path
}

func TestReadInventoryRejectsIncompleteFiles(t *testing.T) {
	cases := []struct {
		name    string
		content string
		want    string
	}{
		{
			name:    "DBInstances が無い",
			content: `{"aws_region": "ap-northeast-1", "ParameterGroups": {}}`,
			want:    "has no DBInstances array",
		},
		{
			name:    "aws_region が無い",
			content: `{"DBInstances": [], "ParameterGroups": {}}`,
			want:    "has no aws_region",
		},
		{
			name:    "aws_region が空白だけ",
			content: `{"aws_region": "  ", "DBInstances": [], "ParameterGroups": {}}`,
			want:    "has no aws_region",
		},
		{
			// 収集器を更新する前の古いインベントリ。黙って time_zone を落とさない。
			name:    "ParameterGroups が無い",
			content: `{"aws_region": "ap-northeast-1", "DBInstances": []}`,
			want:    "has no ParameterGroups object",
		},
		{
			name:    "JSON として壊れている",
			content: `{`,
			want:    "cannot read RDS inventory",
		},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			_, err := ReadInventory(writeInventoryFile(t, testCase.content))
			if err == nil {
				t.Fatal("ReadInventory succeeded, want failure")
			}
			if !strings.Contains(err.Error(), testCase.want) {
				t.Errorf("error = %v, want it to contain %q", err, testCase.want)
			}
		})
	}
}

func TestReadInventoryKeepsUnknownFields(t *testing.T) {
	inventory, err := ReadInventory(writeInventoryFile(t, completeInventory))
	if err != nil {
		t.Fatalf("ReadInventory: %v", err)
	}
	if got := inventory.DBInstances[0].DBInstanceClass; got != "db.t4g.small" {
		t.Errorf("DBInstanceClass = %q", got)
	}

	// 収集器が知らない項目も落とさずに書き戻す。
	encoded, err := json.Marshal(inventory.DBInstances[0])
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	if !strings.Contains(string(encoded), `"ParameterApplyStatus"`) {
		t.Errorf("unknown field was dropped: %s", encoded)
	}
}

func TestIndexInstancesRejectsDuplicates(t *testing.T) {
	inventory := &Inventory{DBInstances: []*DBInstance{
		{DBInstanceIdentifier: "blue"},
		{DBInstanceIdentifier: "blue"},
	}}
	if _, err := inventory.IndexInstances(); err == nil {
		t.Fatal("IndexInstances succeeded, want failure")
	}

	// 識別子の無い要素は無視する（応答の欠けで落とさない）。
	inventory = &Inventory{DBInstances: []*DBInstance{{DBInstanceIdentifier: "blue"}, {}, nil}}
	indexed, err := inventory.IndexInstances()
	if err != nil {
		t.Fatalf("IndexInstances: %v", err)
	}
	if len(indexed) != 1 {
		t.Errorf("indexed = %v, want only blue", indexed)
	}
}

func TestSourceParameterGroupName(t *testing.T) {
	one := &DBInstance{DBParameterGroups: []DBParameterGroupRef{{DBParameterGroupName: "blue-v1"}}}
	name, err := one.SourceParameterGroupName("ctx")
	if err != nil || name != "blue-v1" {
		t.Fatalf("name = %q, err = %v", name, err)
	}

	// 複数関連付いている構成はどれが移行元か決められないため落とす。
	two := &DBInstance{DBParameterGroups: []DBParameterGroupRef{
		{DBParameterGroupName: "a"}, {DBParameterGroupName: "b"},
	}}
	if _, err := two.SourceParameterGroupName("ctx"); err == nil {
		t.Error("two groups accepted, want failure")
	}
	if _, err := (&DBInstance{}).SourceParameterGroupName("ctx"); err == nil {
		t.Error("zero groups accepted, want failure")
	}
	empty := &DBInstance{DBParameterGroups: []DBParameterGroupRef{{}}}
	if _, err := empty.SourceParameterGroupName("ctx"); err == nil {
		t.Error("empty group name accepted, want failure")
	}
}

func TestParameterGroupOfRequiresCollectedFacts(t *testing.T) {
	inventory := &Inventory{ParameterGroups: map[string]*ParameterGroupFacts{
		"blue-v1": {Parameters: map[string]ParameterValue{
			"time_zone": {Value: "Asia/Tokyo", Source: "user"},
		}},
	}}
	facts, err := inventory.ParameterGroupOf("blue-v1", "ctx")
	if err != nil {
		t.Fatalf("ParameterGroupOf: %v", err)
	}
	timeZone, found := facts.Parameter("time_zone")
	if !found || timeZone.Value != "Asia/Tokyo" || timeZone.Source != "user" {
		t.Errorf("time_zone = %+v found=%v", timeZone, found)
	}
	// 採取していないパラメータは found=false で返す。
	if _, found := facts.Parameter("max_connections"); found {
		t.Error("uncollected parameter reported as found")
	}
	if _, err := inventory.ParameterGroupOf("absent-v1", "ctx"); err == nil {
		t.Error("absent group accepted, want failure")
	}
}
