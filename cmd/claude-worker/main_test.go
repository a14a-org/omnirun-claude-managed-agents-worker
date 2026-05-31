package main

import (
	"reflect"
	"testing"
)

func TestMissingEnv(t *testing.T) {
	tests := []struct {
		name   string
		keys   []string
		env    map[string]string
		want   []string
	}{
		{
			name: "all present",
			keys: []string{"A", "B"},
			env:  map[string]string{"A": "x", "B": "y"},
			want: nil,
		},
		{
			name: "all missing",
			keys: []string{"A", "B"},
			env:  map[string]string{},
			want: []string{"A", "B"},
		},
		{
			name: "one missing preserves order",
			keys: []string{"A", "B", "C"},
			env:  map[string]string{"A": "x", "C": "z"},
			want: []string{"B"},
		},
		{
			name: "empty string counts as missing",
			keys: []string{"A"},
			env:  map[string]string{"A": ""},
			want: []string{"A"},
		},
		{
			name: "no keys",
			keys: nil,
			env:  map[string]string{"A": "x"},
			want: nil,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			lookup := func(k string) string { return tt.env[k] }
			got := missingEnv(tt.keys, lookup)
			if !reflect.DeepEqual(got, tt.want) {
				t.Errorf("missingEnv(%v) = %v, want %v", tt.keys, got, tt.want)
			}
		})
	}
}
