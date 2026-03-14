// Primitive Character Definitions
// FF7-style low-poly characters defined as parametric skeleton meshes.
// Each character is a tree of bones. Each bone has a primitive shape.
// Walk and idle animations are keyframe sequences of bone rotations.
// The geometry is Pythagorean — golden ratios, integer proportions,
// the body as a Greek temple.

// Golden ratio
const PHI = (1 + Math.sqrt(5)) / 2
const INV_PHI = 1 / PHI

// Character scale: 1 unit ≈ 10cm. A person is ~17 units tall.
// FF7 field models were about 40 polygons total.

export function createCloud() {
  return {
    name: "Cloud Strife",
    height: 17,
    skeleton: {
      // Root bone — hips
      hips: {
        position: [0, 8.5, 0],
        shape: "box", size: [3.2, 2, 1.8],
        color: 0x2a2a5a, // dark indigo pants
        children: {
          // Torso
          spine: {
            position: [0, 2.5, 0],
            shape: "box", size: [3.5, 3.5, 2],
            color: 0x3333aa, // SOLDIER uniform purple
            children: {
              // Head
              neck: {
                position: [0, 2.2, 0],
                shape: "cylinder", size: [0.4, 0.4, 0.6],
                color: 0xdeb887,
                children: {
                  head: {
                    position: [0, 1.0, 0],
                    shape: "sphere", size: [1.1],
                    color: 0xdeb887, // skin
                    children: {
                      // THE HAIR — Cloud's hair is three angular slabs
                      hair_main: {
                        position: [0, 0.6, -0.2],
                        rotation: [-0.2, 0, 0],
                        shape: "box", size: [1.8, 1.2, 1.0],
                        color: 0xffd700 // gold
                      },
                      hair_spike_1: {
                        position: [0.7, 1.0, -0.3],
                        rotation: [0, 0, 0.7],
                        shape: "box", size: [0.4, 1.5, 0.3],
                        color: 0xffd700
                      },
                      hair_spike_2: {
                        position: [-0.5, 1.2, -0.2],
                        rotation: [0, 0, -0.5],
                        shape: "box", size: [0.3, 1.3, 0.3],
                        color: 0xffd700
                      },
                      hair_spike_3: {
                        position: [0.2, 1.3, -0.5],
                        rotation: [0.4, 0, 0.3],
                        shape: "box", size: [0.3, 1.0, 0.3],
                        color: 0xffd700
                      },
                      // Eyes — two small dark spheres
                      eye_left: {
                        position: [-0.35, 0.1, 0.9],
                        shape: "sphere", size: [0.15],
                        color: 0x00ccff // mako glow
                      },
                      eye_right: {
                        position: [0.35, 0.1, 0.9],
                        shape: "sphere", size: [0.15],
                        color: 0x00ccff
                      }
                    }
                  }
                }
              },
              // Shoulder pauldron (left — the big one)
              shoulder_l: {
                position: [-2.2, 1.5, 0],
                shape: "box", size: [1.5, 1.2, 1.5],
                color: 0x555555, // metal gray
                children: {
                  arm_upper_l: {
                    position: [0, -1.8, 0],
                    shape: "box", size: [1.0, 2.2, 1.0],
                    color: 0x3333aa,
                    children: {
                      arm_lower_l: {
                        position: [0, -2.0, 0],
                        shape: "box", size: [0.8, 2.0, 0.8],
                        color: 0xdeb887,
                        children: {
                          hand_l: {
                            position: [0, -1.2, 0],
                            shape: "sphere", size: [0.5],
                            color: 0xdeb887
                          }
                        }
                      }
                    }
                  }
                }
              },
              // Right arm + Buster Sword
              shoulder_r: {
                position: [2.2, 1.5, 0],
                shape: "box", size: [1.0, 0.8, 1.0],
                color: 0x555555,
                children: {
                  arm_upper_r: {
                    position: [0, -1.8, 0],
                    shape: "box", size: [1.0, 2.2, 1.0],
                    color: 0x3333aa,
                    children: {
                      arm_lower_r: {
                        position: [0, -2.0, 0],
                        shape: "box", size: [0.8, 2.0, 0.8],
                        color: 0xdeb887,
                        children: {
                          hand_r: {
                            position: [0, -1.2, 0],
                            shape: "sphere", size: [0.5],
                            color: 0xdeb887,
                            children: {
                              // THE BUSTER SWORD
                              buster_sword: {
                                position: [0.3, -0.5, -0.8],
                                rotation: [0.3, 0, 0.1],
                                shape: "box", size: [0.6, 7.0, 0.15],
                                color: 0x888888,
                                children: {
                                  sword_guard: {
                                    position: [0, 3.2, 0],
                                    shape: "box", size: [1.5, 0.3, 0.3],
                                    color: 0x666666
                                  }
                                }
                              }
                            }
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          },
          // Left leg
          leg_upper_l: {
            position: [-1.0, -1.5, 0],
            shape: "box", size: [1.2, 2.5, 1.2],
            color: 0x2a2a5a,
            children: {
              leg_lower_l: {
                position: [0, -2.5, 0],
                shape: "box", size: [1.0, 2.5, 1.0],
                color: 0x2a2a5a,
                children: {
                  foot_l: {
                    position: [0, -1.5, 0.3],
                    shape: "box", size: [1.0, 0.5, 1.5],
                    color: 0x333333 // dark boots
                  }
                }
              }
            }
          },
          // Right leg
          leg_upper_r: {
            position: [1.0, -1.5, 0],
            shape: "box", size: [1.2, 2.5, 1.2],
            color: 0x2a2a5a,
            children: {
              leg_lower_r: {
                position: [0, -2.5, 0],
                shape: "box", size: [1.0, 2.5, 1.0],
                color: 0x2a2a5a,
                children: {
                  foot_r: {
                    position: [0, -1.5, 0.3],
                    shape: "box", size: [1.0, 0.5, 1.5],
                    color: 0x333333
                  }
                }
              }
            }
          }
        }
      }
    },
    animations: {
      idle: {
        duration: 2.0,
        loop: true,
        keyframes: {
          spine: [
            { t: 0.0, rotation: [0, 0, 0] },
            { t: 0.5, rotation: [0.03, 0, 0] },
            { t: 1.0, rotation: [0, 0, 0] }
          ],
          arm_upper_l: [
            { t: 0.0, rotation: [0, 0, 0.05] },
            { t: 0.5, rotation: [0.05, 0, 0.08] },
            { t: 1.0, rotation: [0, 0, 0.05] }
          ],
          arm_upper_r: [
            { t: 0.0, rotation: [0, 0, -0.05] },
            { t: 0.5, rotation: [0.03, 0, -0.08] },
            { t: 1.0, rotation: [0, 0, -0.05] }
          ]
        }
      },
      walk: {
        duration: 0.8,
        loop: true,
        keyframes: {
          hips: [
            { t: 0.0, position: [0, 8.5, 0] },
            { t: 0.25, position: [0, 8.8, 0] },
            { t: 0.5, position: [0, 8.5, 0] },
            { t: 0.75, position: [0, 8.8, 0] },
            { t: 1.0, position: [0, 8.5, 0] }
          ],
          leg_upper_l: [
            { t: 0.0, rotation: [-0.5, 0, 0] },
            { t: 0.25, rotation: [0, 0, 0] },
            { t: 0.5, rotation: [0.5, 0, 0] },
            { t: 0.75, rotation: [0, 0, 0] },
            { t: 1.0, rotation: [-0.5, 0, 0] }
          ],
          leg_upper_r: [
            { t: 0.0, rotation: [0.5, 0, 0] },
            { t: 0.25, rotation: [0, 0, 0] },
            { t: 0.5, rotation: [-0.5, 0, 0] },
            { t: 0.75, rotation: [0, 0, 0] },
            { t: 1.0, rotation: [0.5, 0, 0] }
          ],
          leg_lower_l: [
            { t: 0.0, rotation: [0.3, 0, 0] },
            { t: 0.25, rotation: [0.8, 0, 0] },
            { t: 0.5, rotation: [0.1, 0, 0] },
            { t: 0.75, rotation: [0, 0, 0] },
            { t: 1.0, rotation: [0.3, 0, 0] }
          ],
          leg_lower_r: [
            { t: 0.0, rotation: [0.1, 0, 0] },
            { t: 0.25, rotation: [0, 0, 0] },
            { t: 0.5, rotation: [0.3, 0, 0] },
            { t: 0.75, rotation: [0.8, 0, 0] },
            { t: 1.0, rotation: [0.1, 0, 0] }
          ],
          arm_upper_l: [
            { t: 0.0, rotation: [0.4, 0, 0.1] },
            { t: 0.5, rotation: [-0.4, 0, 0.1] },
            { t: 1.0, rotation: [0.4, 0, 0.1] }
          ],
          arm_upper_r: [
            { t: 0.0, rotation: [-0.4, 0, -0.1] },
            { t: 0.5, rotation: [0.4, 0, -0.1] },
            { t: 1.0, rotation: [-0.4, 0, -0.1] }
          ],
          spine: [
            { t: 0.0, rotation: [0, -0.05, 0] },
            { t: 0.5, rotation: [0, 0.05, 0] },
            { t: 1.0, rotation: [0, -0.05, 0] }
          ]
        }
      }
    }
  }
}

export function createLaraCroft() {
  return {
    name: "Lara Croft",
    height: 16.5,
    skeleton: {
      hips: {
        position: [0, 8, 0],
        shape: "box", size: [2.8, 1.8, 1.6],
        color: 0x4a3728, // brown shorts
        children: {
          spine: {
            position: [0, 2.2, 0],
            shape: "box", size: [3.0, 3.0, 1.8],
            color: 0x44bbbb, // iconic teal tank top
            children: {
              // THE GEOMETRY — Lara's defining topology
              chest_l: {
                position: [-0.7, 0.5, 0.5],
                shape: "sphere", size: [0.9],
                color: 0x44bbbb
              },
              chest_r: {
                position: [0.7, 0.5, 0.5],
                shape: "sphere", size: [0.9],
                color: 0x44bbbb
              },
              neck: {
                position: [0, 2.0, 0],
                shape: "cylinder", size: [0.35, 0.35, 0.5],
                color: 0xdeb887,
                children: {
                  head: {
                    position: [0, 0.9, 0],
                    shape: "sphere", size: [1.0],
                    color: 0xdeb887,
                    children: {
                      // Ponytail — single angular slab
                      ponytail: {
                        position: [0, 0.2, -0.8],
                        rotation: [0.8, 0, 0],
                        shape: "box", size: [0.4, 2.5, 0.3],
                        color: 0x5c3317 // dark brown
                      },
                      // Hair front
                      hair_front: {
                        position: [0, 0.5, 0.1],
                        shape: "box", size: [1.2, 0.4, 0.8],
                        color: 0x5c3317
                      },
                      // Sunglasses on head
                      glasses: {
                        position: [0, 0.6, 0.6],
                        shape: "box", size: [1.1, 0.2, 0.3],
                        color: 0x111111
                      },
                      eye_left: {
                        position: [-0.3, 0.0, 0.85],
                        shape: "sphere", size: [0.12],
                        color: 0x6b4226
                      },
                      eye_right: {
                        position: [0.3, 0.0, 0.85],
                        shape: "sphere", size: [0.12],
                        color: 0x6b4226
                      }
                    }
                  }
                }
              },
              // Left arm
              shoulder_l: {
                position: [-2.0, 1.2, 0],
                shape: "sphere", size: [0.5],
                color: 0xdeb887,
                children: {
                  arm_upper_l: {
                    position: [0, -1.5, 0],
                    shape: "box", size: [0.8, 2.0, 0.8],
                    color: 0xdeb887, // bare arms
                    children: {
                      arm_lower_l: {
                        position: [0, -1.8, 0],
                        shape: "box", size: [0.7, 1.8, 0.7],
                        color: 0xdeb887,
                        children: {
                          hand_l: {
                            position: [0, -1.0, 0],
                            shape: "sphere", size: [0.4],
                            color: 0xdeb887,
                            children: {
                              // Left pistol
                              pistol_l: {
                                position: [0, -0.3, 0.4],
                                rotation: [1.2, 0, 0],
                                shape: "box", size: [0.2, 0.8, 0.15],
                                color: 0x333333
                              }
                            }
                          }
                        }
                      }
                    }
                  }
                }
              },
              // Right arm
              shoulder_r: {
                position: [2.0, 1.2, 0],
                shape: "sphere", size: [0.5],
                color: 0xdeb887,
                children: {
                  arm_upper_r: {
                    position: [0, -1.5, 0],
                    shape: "box", size: [0.8, 2.0, 0.8],
                    color: 0xdeb887,
                    children: {
                      arm_lower_r: {
                        position: [0, -1.8, 0],
                        shape: "box", size: [0.7, 1.8, 0.7],
                        color: 0xdeb887,
                        children: {
                          hand_r: {
                            position: [0, -1.0, 0],
                            shape: "sphere", size: [0.4],
                            color: 0xdeb887,
                            children: {
                              pistol_r: {
                                position: [0, -0.3, 0.4],
                                rotation: [1.2, 0, 0],
                                shape: "box", size: [0.2, 0.8, 0.15],
                                color: 0x333333
                              }
                            }
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          },
          // Holster belt
          holster_belt: {
            position: [0, -0.3, 0],
            shape: "box", size: [3.5, 0.3, 2.0],
            color: 0x5c3317,
            children: {
              holster_l: {
                position: [-1.5, -1.0, 0.3],
                shape: "box", size: [0.4, 1.2, 0.3],
                color: 0x5c3317
              },
              holster_r: {
                position: [1.5, -1.0, 0.3],
                shape: "box", size: [0.4, 1.2, 0.3],
                color: 0x5c3317
              }
            }
          },
          // Left leg
          leg_upper_l: {
            position: [-0.9, -1.5, 0],
            shape: "box", size: [1.1, 2.5, 1.1],
            color: 0xdeb887, // bare legs (shorts)
            children: {
              leg_lower_l: {
                position: [0, -2.5, 0],
                shape: "box", size: [0.9, 2.5, 0.9],
                color: 0xdeb887,
                children: {
                  foot_l: {
                    position: [0, -1.5, 0.2],
                    shape: "box", size: [0.9, 0.5, 1.4],
                    color: 0x4a3728 // brown boots
                  }
                }
              }
            }
          },
          // Right leg
          leg_upper_r: {
            position: [0.9, -1.5, 0],
            shape: "box", size: [1.1, 2.5, 1.1],
            color: 0xdeb887,
            children: {
              leg_lower_r: {
                position: [0, -2.5, 0],
                shape: "box", size: [0.9, 2.5, 0.9],
                color: 0xdeb887,
                children: {
                  foot_r: {
                    position: [0, -1.5, 0.2],
                    shape: "box", size: [0.9, 0.5, 1.4],
                    color: 0x4a3728
                  }
                }
              }
            }
          }
        }
      }
    },
    animations: {
      idle: {
        duration: 2.5,
        loop: true,
        keyframes: {
          spine: [
            { t: 0.0, rotation: [0, 0, 0] },
            { t: 0.5, rotation: [0.02, 0, 0] },
            { t: 1.0, rotation: [0, 0, 0] }
          ],
          ponytail: [
            { t: 0.0, rotation: [0.8, 0, 0] },
            { t: 0.3, rotation: [0.85, 0.05, 0] },
            { t: 0.7, rotation: [0.75, -0.05, 0] },
            { t: 1.0, rotation: [0.8, 0, 0] }
          ],
          arm_upper_l: [
            { t: 0.0, rotation: [0, 0, 0.15] },
            { t: 0.5, rotation: [0.03, 0, 0.18] },
            { t: 1.0, rotation: [0, 0, 0.15] }
          ],
          arm_upper_r: [
            { t: 0.0, rotation: [0, 0, -0.15] },
            { t: 0.5, rotation: [0.03, 0, -0.18] },
            { t: 1.0, rotation: [0, 0, -0.15] }
          ]
        }
      },
      walk: {
        duration: 0.7,
        loop: true,
        keyframes: {
          hips: [
            { t: 0.0, position: [0, 8, 0] },
            { t: 0.25, position: [0, 8.2, 0] },
            { t: 0.5, position: [0, 8, 0] },
            { t: 0.75, position: [0, 8.2, 0] },
            { t: 1.0, position: [0, 8, 0] }
          ],
          leg_upper_l: [
            { t: 0.0, rotation: [-0.6, 0, 0] },
            { t: 0.25, rotation: [0, 0, 0] },
            { t: 0.5, rotation: [0.6, 0, 0] },
            { t: 0.75, rotation: [0, 0, 0] },
            { t: 1.0, rotation: [-0.6, 0, 0] }
          ],
          leg_upper_r: [
            { t: 0.0, rotation: [0.6, 0, 0] },
            { t: 0.25, rotation: [0, 0, 0] },
            { t: 0.5, rotation: [-0.6, 0, 0] },
            { t: 0.75, rotation: [0, 0, 0] },
            { t: 1.0, rotation: [0.6, 0, 0] }
          ],
          leg_lower_l: [
            { t: 0.0, rotation: [0.4, 0, 0] },
            { t: 0.25, rotation: [0.9, 0, 0] },
            { t: 0.5, rotation: [0.1, 0, 0] },
            { t: 0.75, rotation: [0, 0, 0] },
            { t: 1.0, rotation: [0.4, 0, 0] }
          ],
          leg_lower_r: [
            { t: 0.0, rotation: [0.1, 0, 0] },
            { t: 0.25, rotation: [0, 0, 0] },
            { t: 0.5, rotation: [0.4, 0, 0] },
            { t: 0.75, rotation: [0.9, 0, 0] },
            { t: 1.0, rotation: [0.1, 0, 0] }
          ],
          arm_upper_l: [
            { t: 0.0, rotation: [0.5, 0, 0.1] },
            { t: 0.5, rotation: [-0.5, 0, 0.1] },
            { t: 1.0, rotation: [0.5, 0, 0.1] }
          ],
          arm_upper_r: [
            { t: 0.0, rotation: [-0.5, 0, -0.1] },
            { t: 0.5, rotation: [0.5, 0, -0.1] },
            { t: 1.0, rotation: [-0.5, 0, -0.1] }
          ],
          ponytail: [
            { t: 0.0, rotation: [0.6, 0.1, 0] },
            { t: 0.25, rotation: [0.9, 0, 0] },
            { t: 0.5, rotation: [0.6, -0.1, 0] },
            { t: 0.75, rotation: [0.9, 0, 0] },
            { t: 1.0, rotation: [0.6, 0.1, 0] }
          ],
          spine: [
            { t: 0.0, rotation: [0, -0.08, 0] },
            { t: 0.5, rotation: [0, 0.08, 0] },
            { t: 1.0, rotation: [0, -0.08, 0] }
          ]
        }
      }
    }
  }
}

export default { createCloud, createLaraCroft }
